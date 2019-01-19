require 'rexml/document'

class Converter
  Done = []

  def initialize(doc, writer)
    @root = doc
    @writer = writer
  end

  def execute
    state = State.new
    @root.each_element { |e| do_element(state, e, @writer) }
  end

  def do_element(state, element, writer)
    rest_element = []
    begin
      rest_element = to_element_converter(element.name).new(self, state, element, writer).dispatch
    rescue NameError => e
      p e
      #puts "Unknown #{element.name}"
      #rest_element = element.elements
    end

    rest_element.each { |e| do_element(state, e, writer) } if rest_element.size > 0
  end

  def to_element_converter(name)
    Converter.const_get(name.split('_').collect(&:capitalize).join.to_sym)
  end

  class State
    TOP = 1
    HEADER = 2
    BODY = 3
    BULLET_LIST = 4
    BULLET_LIST_ITEM = 5
    SECTION = 6
    NOTE = 7
    FOOTNOTE = 8

    attr_accessor :depth

    def initialize(state: TOP, depth: 0)
      @current = state
      @depth = depth
    end

    def current
      @current
    end

    def set(state)
      @current = state
    end

    def left
      @depth -= 1 if @depth > 0
    end

    def right
      @depth += 1
    end
  end

  class Element
    attr_reader :converter, :state, :element, :writer

    def initialize(converter, state, element, writer)
      @converter = converter
      @state = state
      @element = element
      @writer = writer
    end

    def dispatch
      raise NotImplementedError
    end

    def Continue
      element.elements
    end

    def Break
      []
    end
  end

  class Title < Element
    def dispatch
      case state.current
      when Converter::State::TOP
        writer.puts(element.text)
        writer.puts("---")
        state.set(Converter::State::HEADER)
      when Converter::State::BODY
        writer.puts("# #{element.text}")
        writer.puts("")
      when Converter::State::SECTION
        writer.puts("")
        writer.print("#" * state.depth)
        writer.print(" ")
        element.each_element do |e|
          converter.do_element(state, e, writer)
        end
        writer.print(" ")
        anchor = element.text.split(" ").join("-").downcase
        writer.print("<a name=\"#{anchor}\">")
        writer.print(element.text)
        writer.puts("</a>")
        writer.puts("")
      end

      Break()
    end
  end

  class Docinfo < Element
    def dispatch
      case state.current
      when Converter::State::HEADER
        writer.puts("")
        element.each_element do |e|
          writer.puts("| #{e.name} | #{e.text} |")
        end
        writer.puts("")
        state.set(Converter::State::BODY)
      end

      Break()
    end
  end

  class Topic < Element
    def dispatch
      case state.current
      when Converter::State::BODY
        element.each_element do |e|
          converter.do_element(state, e, writer)
        end
      end

      Break()
    end
  end

  class Paragraph < Element
    def dispatch
      case state.current
      when Converter::State::BULLET_LIST_ITEM
        standard_puts
      when Converter::State::SECTION
        standard_puts
        writer.puts("")
      when Converter::State::NOTE
        element.each_child do |e|
          case e
          when REXML::Text
            writer.puts("> #{e.to_s}")
          end
          writer.puts("")
        end
      when Converter::State::FOOTNOTE
        standard_print
      end

      Break()
    end

    def standard_puts
      print(&writer.method(:puts))
    end

    def standard_print
      print(&writer.method(:print))
    end

    def print(&print_method)
      element.each_child do |e|
        case e
        when REXML::Text
          print_method.call(e.to_s)
        when REXML::Element
          converter.do_element(state, e, writer)
        end
      end
    end
  end

  class Section < Element
    def dispatch
      state.set(Converter::State::SECTION)
      state.right

      element.each_element do |e|
        converter.do_element(state.clone, e, writer)
      end

      state.left

      Break()
    end
  end

  class Note < Element
    def dispatch
      state.set(Converter::State::NOTE)

      element.each_element do |e|
        converter.do_element(state.clone, e, writer)
      end

      Break()
    end
  end

  class BulletList < Element
    def dispatch
      prev = nil
      list_state = state.clone
      case state.current
      when Converter::State::BODY
        list_state.depth = 0
        list_state.set(Converter::State::BULLET_LIST)
      when Converter::State::SECTION
        prev = state.current
        list_state.depth = 0
        list_state.set(Converter::State::BULLET_LIST)
      when Converter::State::BULLET_LIST_ITEM
        list_state.right
      end

      element.each_element do |e|
        converter.do_element(list_state, e, writer)
      end

      state.set(prev) unless prev.nil?

      writer.puts("") if list_state.depth == 0
      Break()
    end
  end

  class ListItem < Element
    def dispatch
      prev = nil
      case state.current
      when Converter::State::BULLET_LIST
        prev = state.current
        state.set(Converter::State::BULLET_LIST_ITEM)
      end

      writer.print("  " * state.depth)
      writer.print("* ")
      element.each_element do |e|
        converter.do_element(state.clone, e, writer)
      end

      state.set(prev) unless prev.nil?

      Break()
    end
  end

  class Reference < Element
    def dispatch
      case state.current
      when Converter::State::BULLET_LIST_ITEM
        element.each_element do |e|
          converter.do_element(state, e, writer)
        end
        link
        writer.puts("")
      when Converter::State::SECTION
        link
      when Converter::State::FOOTNOTE
        link
        writer.puts("")
      end

      Break()
    end

    def link
      if element.attribute('refuri')
        text = element.text || element.attribute('refuri').value
        writer.print(" [#{text}](#{element.attribute('refuri')}) ")
      elsif element.attribute('refid') && element.attribute('name')
        writer.print(" [#{element.text}](##{anchor(element.attribute('name').value)}) ")
      elsif element.attribute('refid')
        writer.print(" [#{element.text}](##{anchor(element.text)}) ")
      end
    end

    def anchor(value)
      value.split(" ").join('-').downcase
    end
  end

  class Figure < Element
    def dispatch
      uri = nil
      caption = nil
      element.each_element do |e|
        case e.name
        when "image"
          uri = e.attribute("uri").value
        when "caption"
          caption = e.text
        end
      end
      writer.puts("![#{caption}](#{uri})")
      writer.puts("")

      Break()
    end
  end

  class Image < Element
    def dispatch
      case state.current
      when Converter::State::FIGURE
        writer.puts("![]")
      end
    end
  end

  class Footnote < Element
    def dispatch
      case state.current
      when Converter::State::SECTION
        state.set(Converter::State::FOOTNOTE)
      end

      Continue()
    end
  end

  class FootnoteReference < Element
    def dispatch
      writer.write("[[#{element.text}]](#footnote_#{element.text})")
      Break()
    end
  end

  class Label < Element
    def dispatch
      case state.current
      when Converter::State::FOOTNOTE
        writer.write("- <a name=\"footnote_#{element.text}\">[#{element.text}]</a> ")
      end
      Break()
    end
  end

  class Literal < Element
    def dispatch
      writer.write(" `#{element.text}` ")
      Break()
    end
  end

  class Generated < Element
    def dispatch
      writer.print("#{element.text.gsub(" ", "")}")

      Break()
    end
  end

  class Target < Element
    def dispatch
      Break()
    end
  end

  class Document < Element
    def dispatch
      Continue()
    end
  end
end

doc = REXML::Document.new(open(ARGV.shift))
Converter.new(doc, STDOUT).execute
