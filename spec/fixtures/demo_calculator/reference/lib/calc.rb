require "json"

# A complete reference calculator for the acceptance tests: + - * / % ** parentheses, --json and a REPL.
module Calc
  class Error < StandardError; end

  class Unsupported < Error; end

  class DivisionByZero < Error
    def initialize = super("division by zero")
  end

  Parser = Struct.new(:tokens) do
    def parse
      v = sum
      raise Unsupported, "unexpected #{tokens.first}" unless tokens.empty?
      v
    end

    def sum
      v = product
      while %w[+ -].include?(tokens.first)
        op = tokens.shift
        r = product
        v = (op == "+") ? v + r : v - r
      end
      v
    end

    def product
      v = unary
      while %w[* / %].include?(tokens.first)
        op = tokens.shift
        r = unary
        raise DivisionByZero if op != "*" && r == 0
        v = case op
            when "*" then v * r
            when "/" then v / r.to_f
            else v % r
            end
      end
      v
    end

    def unary
      return -tokens.shift.then { unary } if tokens.first == "-"
      power
    end

    def power
      base = primary
      return base unless tokens.first == "**"
      tokens.shift
      base**unary
    end

    def primary
      t = tokens.shift
      if t == "("
        v = sum
        raise Unsupported, "missing )" unless tokens.shift == ")"
        v
      elsif t&.match?(/\A\d/)
        t.include?(".") ? t.to_f : t.to_i
      else
        raise Unsupported, "unsupported: #{t}"
      end
    end
  end

  # @return [Numeric]
  def self.evaluate(expression)
    tokens = expression.scan(%r{\d+\.?\d*|\.\d+|\*\*|[-+*/%()]|\S})
    Parser.new(tokens).parse
  end

  def self.format(value)
    (value.is_a?(Float) && value == value.to_i) ? value.to_i.to_s : value.to_s
  end

  module CLI
    def self.run(argv, input, out, err)
      json = argv.first == "--json"
      argv = argv.drop(1) if json
      return repl(input, out, err) if argv.empty? && !json
      expression = argv.join(" ")
      begin
        result = Calc.evaluate(expression)
        out.puts(json ? JSON.generate("expression" => expression, "result" => result) : Calc.format(result))
        0
      rescue DivisionByZero, Unsupported => e
        json ? out.puts(JSON.generate("expression" => expression, "error" => e.message)) : err.puts("error: #{e.message}")
        1
      end
    end

    def self.repl(input, out, err)
      loop do
        out.print "> "
        out.flush
        line = input.gets
        break if line.nil? || %w[exit quit].include?(line.strip)
        next if line.strip.empty?
        begin
          out.puts Calc.format(Calc.evaluate(line))
        rescue Error => e
          err.puts "error: #{e.message}"
        end
      end
      out.puts
      0
    end
  end
end
