module Workspace
  class CLI
    # One run of the CLI as the helpers see it: the streams and exit handler to use, and the two
    # flags read from the whole argument list before any verb parses it. {CLI#run} builds one per
    # run, so the nested run of `--help --json` gets its own over the buffers it captures into.
    #
    # @!attribute [r] output
    #   @return [IO] where documents and plain output go
    # @!attribute [r] error_output
    #   @return [IO] where warnings and errors go
    # @!attribute [r] exit_handler
    #   @return [#exit]
    # @!attribute [r] help_asked
    #   @return [Boolean] `--help` or `-h` came before a bare `--`, so names are matched exactly
    # @!attribute [r] quiet
    #   @return [Boolean] `--json` came before a bare `--`, so no "Workspace 'x' is y." line is printed
    # @!attribute [r] env
    #   @return [#[]] the environment the run reads
    Invocation = Data.define(:output, :error_output, :exit_handler, :help_asked, :quiet, :env)
  end
end
