require "delegate"

module Workspace
  # The input stream every collaborator reads answers from. It wraps the real
  # stream and, once told to refuse (`--no-input` or `WORKSPACE_NO_INPUT`),
  # lets {Prompt.ask} fail instead of waiting for a person. Everything else,
  # such as the hook payload `session-event` reads, passes through untouched.
  class PromptInput < SimpleDelegator
    # @param env [Hash] the environment to read `WORKSPACE_NO_INPUT` from
    # @return [Boolean] whether `WORKSPACE_NO_INPUT` is set to something other than empty, 0 or false
    def self.env_truthy?(env)
      !["", "0", "false"].include?(env["WORKSPACE_NO_INPUT"].to_s.strip.downcase)
    end

    # @param io [IO] the stream to wrap
    # @param no_input [Boolean] refuse prompts from the start
    def initialize(io, no_input: false)
      super(io)
      @no_input = no_input
    end

    # @return [Boolean] whether prompts are refused
    def no_input?
      @no_input
    end

    # Refuses prompts from now on.
    #
    # @return [void]
    def no_input!
      @no_input = true
    end
  end

  # Asks a person a question on the terminal, or refuses when input is off.
  module Prompt
    # Prints `text` and reads one line. When `input` is a {PromptInput} that
    # refuses prompts, raises before printing or reading anything.
    #
    # @param input [IO, PromptInput] where the answer comes from
    # @param output [IO] where the prompt is printed
    # @param text [String] the prompt, as shown to a person
    # @param retry_flags [Array<String>] flags that answer the prompt without asking
    # @param destructive [Boolean] whether those flags discard or remove something
    # @return [String, nil] the line read, nil at end of input
    # @raise [Workspace::Error] code `confirmation_required` when input is off
    def self.ask(input, output, text, retry_flags: [], destructive: false)
      refuse_if_no_input!(input, text, retry_flags: retry_flags, destructive: destructive)
      output.print text
      input.gets
    end

    # Raises when `input` refuses prompts; does nothing otherwise. For callers
    # that know a prompt is coming before they reach it.
    #
    # @param input [IO, PromptInput]
    # @param text [String] the prompt that would be shown
    # @param retry_flags [Array<String>]
    # @param destructive [Boolean]
    # @return [void]
    # @raise [Workspace::Error] code `confirmation_required` when input is off
    def self.refuse_if_no_input!(input, text, retry_flags: [], destructive: false)
      return unless input.respond_to?(:no_input?) && input.no_input?

      prompt = text.strip
      raise Error.new("Can't ask \"#{prompt}\" with --no-input (or WORKSPACE_NO_INPUT) set.",
        code: "confirmation_required", details: {"prompt" => prompt},
        retry_with: retry_flags.empty? ? nil : {"flags" => retry_flags, "destructive" => destructive})
    end
  end
end
