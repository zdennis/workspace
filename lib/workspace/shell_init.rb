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

      function _workspace_wf_ids {
        [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh
        command workspace workflow show 2>/dev/null | command awk '$1 ~ /^[a-z0-9][a-z0-9_-]{0,39}$/ && $0 !~ /INVALID:/ { print $1 }'
      }

      function _workspace_wf_refs {
        [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh
        local wf_gh wf_dog
        command git for-each-ref --format='%(refname:lstrip=2)' refs/heads 2>/dev/null || :
        command -v gh >/dev/null 2>&1 || return 0
        GH_PROMPT_DISABLED=1 command gh pr list --limit 30 --json number,title --jq '.[] | "#\(.number)\t\(.title | gsub("[\u0001-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069]"; " "))"' 2>/dev/null &
        wf_gh=$!
        (
          command sleep 5 >/dev/null 2>&1
          builtin kill "$wf_gh" >/dev/null 2>&1
        ) >/dev/null 2>&1 &
        wf_dog=$!
        builtin wait "$wf_gh" >/dev/null 2>&1 || :
        builtin kill "$wf_dog" >/dev/null 2>&1 || :
        return 0
      }

      function wfp {
        [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh
        local wf_ids wf_id wf_out wf_rc wf_query wf_sel wf_ref wf_tab wf_nl wf_num wf_count
        if [ "$#" -gt 0 ]; then
          builtin printf '%s\n' 'Usage: wfp   (takes no arguments; use wf to pass them)' >&2
          return 1
        fi
        wf_tab=$'\t'
        wf_nl=$'\n'
        wf_ids="$(_workspace_wf_ids)"
        if [ -z "$wf_ids" ]; then
          builtin printf '%s\n' 'wfp: no workflows (see: workspace workflow show)' >&2
          return 1
        fi
        if command -v fzf >/dev/null 2>&1; then
          wf_rc=0
          wf_out="$(builtin printf '%s\n' "$wf_ids" | command fzf --no-multi --no-preview --prompt='workflow> ')" || wf_rc=$?
          [ "$wf_rc" -eq 130 ] && return 130
          wf_id="${wf_out%%"$wf_tab"*}"
          if [ "$wf_rc" -ne 0 ] || [ -z "$wf_id" ]; then
            builtin printf '%s\n' 'wfp: no workflow picked; nothing started' >&2
            return 1
          fi
          wf_rc=0
          wf_out="$( { (exec 2>/dev/null </dev/null; _workspace_wf_refs) & } | command fzf --no-multi --no-preview --print-query --bind=alt-enter:print-query --prompt='ref (Alt-Enter: use typed text)> ')" || wf_rc=$?
          [ "$wf_rc" -eq 130 ] && return 130
          if [ "$wf_rc" -ne 0 ] && [ "$wf_rc" -ne 1 ]; then
            builtin printf '%s\n' "wfp: fzf failed (exit $wf_rc); nothing started" >&2
            return 1
          fi
          wf_query="${wf_out%%"$wf_nl"*}"
          wf_ref="$wf_query"
          case "$wf_out" in
            *"$wf_nl"*)
              if [ "$wf_rc" -eq 0 ]; then
                wf_sel="${wf_out#*"$wf_nl"}"
                wf_ref="${wf_sel%%"$wf_tab"*}"
              fi
              ;;
          esac
          [ -n "$wf_ref" ] || { builtin printf '%s\n' 'wfp: no ref or text given; nothing started' >&2; return 1; }
        else
          builtin printf '%s\n' "$wf_ids" | command awk '{ printf "%d) %s\n", NR, $0 }'
          builtin printf '%s' 'Workflow number: '
          if ! IFS= builtin read -r wf_num && [ -z "$wf_num" ]; then
            builtin printf '\n'
            return 1
          fi
          case "$wf_num" in
            '')
              builtin printf '%s\n' "wfp: no number given; nothing started" >&2
              return 1
              ;;
            *[!0-9]*)
              builtin printf '%s\n' "wfp: not a workflow number: $wf_num" >&2
              return 1
              ;;
          esac
          wf_count="$(builtin printf '%s\n' "$wf_ids" | command awk 'END { print NR }')"
          if [ "${#wf_num}" -gt 6 ] || [ "$wf_num" -lt 1 ] || [ "$wf_num" -gt "$wf_count" ]; then
            builtin printf '%s\n' "wfp: choose a number from 1 to $wf_count" >&2
            return 1
          fi
          wf_id="$(builtin printf '%s\n' "$wf_ids" | command sed -n "${wf_num}p")"
          builtin printf '%s' "Ref or text (branch, '#12', or words): "
          if ! IFS= builtin read -r wf_ref && [ -z "$wf_ref" ]; then
            builtin printf '\n'
            return 1
          fi
          [ -n "$wf_ref" ] || { builtin printf '%s\n' 'wfp: no ref or text given; nothing started' >&2; return 1; }
        fi
        _workspace_wf_start "$wf_id" 0 "$wf_ref"
      }
    SH

    # What differs between the shells.
    # standard:disable Style/RedundantHeredocDelimiterQuotes -- quoted on purpose: no part of the text is ever interpolated
    PER_SHELL = {
      "zsh" => <<~'SH',
        # workspace shell-init zsh
        function _workspace_complete {
          local wf_list wf_ids
          if [ "${words[1]:t}" = wf ]; then
            if [ "$CURRENT" -ge 3 ] && [ "${words[CURRENT-1]}" = -w ]; then
              wf_ids=(${(f)"$(_workspace_wf_ids)"})
              compadd -a wf_ids
              return 0
            fi
          elif [ "$CURRENT" -eq 2 ]; then
            wf_list=(init doctor launch start stop add add-project kill rename finish relaunch restore focus deactivate reactivate tile resize capture agent agentd lock dev parent notes plan ticket skills spine journey goal pr rebase push promote projects go capabilities daemon sessions review snapshot ask inbox hooks session-event agent-run handoff pipeline run library lib instructions workflow step run-and-report report-run-status layout config tmux statusline current list-projects list status repair cleanup prune set-command event-log events whereis lookup dir alfred shell-init version help)
            compadd -a wf_list
            return 0
          elif [ "${words[2]}" = workflow ]; then
            if [ "$CURRENT" -eq 3 ]; then
              wf_list=(show validate add update remove run start render check simulate status events files attempts audit stats compare sweep resume cancel approve reject)
              compadd -a wf_list
              return 0
            elif [ "$CURRENT" -eq 4 ]; then
              case "${words[3]}" in
                start | show | run | update | remove)
                  wf_ids=(${(f)"$(_workspace_wf_ids)"})
                  compadd -a wf_ids
                  return 0
                  ;;
              esac
            fi
          fi
          _files || :
          return 0
        }
        
        if [ "${+functions[compdef]}" = 1 ]; then
          compdef _workspace_complete workspace wf
        fi
      SH
      "bash" => <<~'SH'
        # workspace shell-init bash
        function _workspace_complete {
          local wf_cur wf_list wf_word wf_cmd IFS
          IFS=$' \t\n'
          COMPREPLY=()
          wf_cur="${COMP_WORDS[COMP_CWORD]}"
          wf_cmd="${COMP_WORDS[0]##*/}"
          wf_list=""
          if [ "$wf_cmd" = wf ]; then
            if [ "$COMP_CWORD" -ge 2 ] && [ "${COMP_WORDS[COMP_CWORD-1]}" = -w ]; then
              wf_list="$(_workspace_wf_ids)"
            fi
          elif [ "$COMP_CWORD" -eq 1 ]; then
            wf_list="init doctor launch start stop add add-project kill rename finish relaunch restore focus deactivate reactivate tile resize capture agent agentd lock dev parent notes plan ticket skills spine journey goal pr rebase push promote projects go capabilities daemon sessions review snapshot ask inbox hooks session-event agent-run handoff pipeline run library lib instructions workflow step run-and-report report-run-status layout config tmux statusline current list-projects list status repair cleanup prune set-command event-log events whereis lookup dir alfred shell-init version help"
          elif [ "${COMP_WORDS[1]}" = workflow ]; then
            if [ "$COMP_CWORD" -eq 2 ]; then
              wf_list="show validate add update remove run start render check simulate status events files attempts audit stats compare sweep resume cancel approve reject"
            elif [ "$COMP_CWORD" -eq 3 ]; then
              case "${COMP_WORDS[2]}" in
                start | show | run | update | remove) wf_list="$(_workspace_wf_ids)" ;;
              esac
            fi
          fi
          for wf_word in $wf_list; do
            case "$wf_word" in
              "$wf_cur"*) COMPREPLY[${#COMPREPLY[@]}]="$wf_word" ;;
            esac
          done
          return 0
        }
        
        if command -v complete >/dev/null 2>&1; then
          complete -o default -F _workspace_complete workspace wf
        fi
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
