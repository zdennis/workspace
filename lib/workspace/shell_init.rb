module Workspace
  # The shell text `workspace shell-init SHELL` prints for an rc file to load.
  # Every part is a single-quoted heredoc: Ruby interpolates nothing into it,
  # so no workflow file name, title or other value can reach the person's shell.
  module ShellInit
    SHELLS = %w[zsh bash].freeze

    # Functions that behave the same in zsh and bash 3.2 or later. `_workspace_wf_start
    # ID DRY WORDS...` is the one place that runs `workflow start`; DRY is a fixed
    # slot (0 or 1), never one of the person's words.
    BODY = <<~'SH'
      function _workspace_wf_usage {
        builtin printf '%s\n' 'Usage: wf [-w ID] [--dry-run] [--] REF' '       wf [-w ID] [--dry-run] [--] TEXT...' >&2
      }

      function _workspace_wf_start {
        [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh
        local wf_id wf_dry wf_text IFS
        wf_id="$1"
        wf_dry="$2"
        shift 2
        IFS=' '
        wf_text="$*"
        if [ -z "$wf_text" ]; then
          _workspace_wf_usage
          return 1
        fi
        if [ "$#" -eq 1 ]; then
          case "$1" in
            *[[:space:]]*)
              if [ "$wf_dry" = 1 ]; then
                command workspace workflow start --dry-run --prompt "$wf_text" -- "$wf_id"
              else
                command workspace workflow start --prompt "$wf_text" -- "$wf_id"
              fi
              return $?
              ;;
          esac
          if [ "$wf_dry" = 1 ]; then
            command workspace workflow start --dry-run -- "$wf_id" "$1"
          else
            command workspace workflow start -- "$wf_id" "$1"
          fi
          return $?
        fi
        if [ "$wf_dry" = 1 ]; then
          command workspace workflow start --dry-run --prompt "$wf_text" -- "$wf_id"
        else
          command workspace workflow start --prompt "$wf_text" -- "$wf_id"
        fi
      }

      function wf {
        [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh
        local wf_id wf_dry
        wf_id="${WORKSPACE_WF_DEFAULT:-rpiv}"
        wf_dry=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -w)
              if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                builtin printf '%s\n' 'wf: -w needs a workflow id' >&2
                _workspace_wf_usage
                return 1
              fi
              wf_id="$2"
              shift 2
              ;;
            --dry-run)
              wf_dry=1
              shift
              ;;
            -h | --help)
              builtin printf '%s\n' 'Usage: wf [-w ID] [--dry-run] [--] REF' '       wf [-w ID] [--dry-run] [--] TEXT...' '' 'Start a workflow (default rpiv, or $WORKSPACE_WF_DEFAULT) on REF, or on' 'TEXT when it is several words or holds whitespace. Use -- before text' 'that starts with a dash.'
              return 0
              ;;
            --)
              shift
              break
              ;;
            -*)
              builtin printf '%s\n' "wf: unknown option: $1 (put -- before text that starts with a dash)" >&2
              return 1
              ;;
            *)
              break
              ;;
          esac
        done
        _workspace_wf_start "$wf_id" "$wf_dry" "$@"
      }
    SH

    # What differs between the shells.
    # standard:disable Style/RedundantHeredocDelimiterQuotes -- quoted on purpose: no part of the text is ever interpolated
    PER_SHELL = {
      "zsh" => <<~'SH',
        # workspace shell-init zsh
      SH
      "bash" => <<~'SH'
        # workspace shell-init bash
      SH
    }.freeze
    # standard:enable Style/RedundantHeredocDelimiterQuotes

    # The text for one shell, to be loaded with `eval "$(workspace shell-init SHELL)"`.
    # @param shell [String] "zsh" or "bash"
    # @return [String] fixed shell text; it prints nothing when loaded
    # @raise [ArgumentError] for any other shell
    def self.text(shell)
      raise ArgumentError, "unknown shell: #{shell.inspect}" unless SHELLS.include?(shell)

      PER_SHELL.fetch(shell) + BODY
    end
  end
end
