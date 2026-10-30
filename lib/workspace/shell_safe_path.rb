module Workspace
  # Which characters of a path a shell command can't hold safely: the ones that end a quote or
  # start a substitution, control characters, and the invisible ones that hide what a path says.
  # The one check behind `unsafe_checkout_path`.
  module ShellSafePath
    NAMED = {
      "'" => "single quote", "\"" => "double quote", "`" => "backtick", "$" => "dollar sign", "\\" => "backslash"
    }.freeze

    CONTROL = /[\u0000-\u001f\u007f-\u009f  ]/
    INVISIBLE = /[​-‏‪-‮⁠⁦-⁩؜᠎﻿]/

    # @param path [String, #to_s]
    # @return [Array<String>] the names of the unsafe characters in the path, once each; empty
    #   when it is safe. Never the path itself.
    def self.unsafe_characters(path)
      path.to_s.scrub.each_char.filter_map do |char|
        NAMED[char] || (format("U+%04X", char.ord) if char.match?(CONTROL) || char.match?(INVISIBLE))
      end.uniq
    end
  end
end
