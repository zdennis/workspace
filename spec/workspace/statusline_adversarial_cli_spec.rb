require "spec_helper"
require "stringio"
require "tmpdir"

# Adversarial CLI/UX coverage for the statusline + context-reading feature
# (workspace statusline, StatuslineRenderer, context.source/pattern config,
# sessions --json context fields). One failing `it` per confirmed defect,
# tagged with an ID for the report.
RSpec.describe "statusline adversarial: CLI/UX" do
  def build_config_command(output: StringIO.new)
    dir = Dir.mktmpdir("ws-config")
    fake_path_config = Struct.new(:workspace_config_dir).new(dir)
    project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
    lineage = Workspace::WorkspaceLineage.new
    file_backup = Workspace::FileBackup.new(output: output)
    command = Workspace::Commands::Config.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output)
    [command, project_settings]
  end

  # U1: capture_group_count (lib/workspace/commands/config.rb:196-199) strips
  # `(?<` via the same gsub that's supposed to detect it, so the later
  # `stripped.scan("(?<")` correction is dead code. A named capture group
  # like `(?<pct>\d+)` is counted as zero capturing groups instead of one,
  # so `workspace config set context.pattern` rejects a perfectly valid,
  # single-capture-group pattern.
  it "U1: accepts a context.pattern using a named capture group" do
    command, = build_config_command

    expect { command.set("context.pattern", '(?<pct>\d+)% ctx') }.not_to raise_error
  end

  # U2: capture_group_count doesn't strip character classes before counting
  # bare "(", so a literal "(" inside a character class (e.g. `[(]`) is
  # miscounted as an extra capturing group, causing a pattern with exactly
  # one real capture group to be rejected.
  it "U2: accepts a context.pattern with a literal '(' inside a character class" do
    command, = build_config_command

    expect { command.set("context.pattern", '[(](\d+)% ctx') }.not_to raise_error
  end

  # U3: docs/README.statusline.md:52 and docs/README.sessions.md:67 document
  # a "no pane id (status-line process lacked $TMUX_PANE)" context_error
  # reason, but lib/workspace/context_reasons.rb only defines NO_READING,
  # PATTERN_NO_MATCH, and NO_PATTERN -- no reader ever emits a "no pane id"
  # string. ContextReader#read(pane_id: nil) falls through to NO_READING
  # instead, so the documented reason can never actually appear.
  it "U3: never returns the documented 'no pane id' context_error reason" do
    context_store = instance_double(Workspace::ContextStore, reading_for_pane: nil)
    project_settings = instance_double(Workspace::ProjectSettings, load_global: {})
    reader = Workspace::ContextReader.new(context_store: context_store, project_settings: project_settings)

    result = reader.read(pane_id: nil, agent_pid: nil)

    expect(result[:error]).to match(/no pane id/)
  end

  # U4: ContextReader#read has no way to detect that a stored reading came
  # from a previous Claude session in a reused tmux pane -- it never
  # compares the stored session_id to the pane's current session_id, so a
  # stale reading from an ended session is reported as if it were current,
  # with no error/staleness signal at all.
  it "U4: does not flag a reading recorded under a different session_id in a reused pane" do
    context_store = instance_double(
      Workspace::ContextStore,
      reading_for_pane: {"pct" => 88, "recorded_at" => "2026-09-20T00:00:00Z", "session_id" => "old-session-abc"}
    )
    project_settings = instance_double(Workspace::ProjectSettings, load_global: {})
    reader = Workspace::ContextReader.new(context_store: context_store, project_settings: project_settings)

    result = reader.read(pane_id: "%1", agent_pid: nil)

    # The reader has no `current_session_id` parameter at all, so it can
    # never compare the stored reading's session_id against the pane's
    # actual current session and flag a mismatch -- it just hands back the
    # stale reading as if it were fresh.
    expect(reader.method(:read).parameters.map(&:last)).to include(:current_session_id)
    expect(result[:pct]).to eq(88)
  end

  # U5: StatuslineRenderer#render coerces `context_window.used_percentage`
  # with a bare `.to_i`. A non-numeric value (e.g. the field being a string
  # like "N/A", which some delegates/tools could plausibly send) silently
  # becomes 0, printed as "0% ctx" -- indistinguishable from a real 0%
  # reading, violating the documented "never estimates a percentage it
  # hasn't actually read" rule (docs/README.statusline.md:57).
  it "U5: does not render a non-numeric used_percentage as a fabricated 0%" do
    renderer = Workspace::StatuslineRenderer.new
    payload = {"model" => {"display_name" => "Sonnet"}, "context_window" => {"used_percentage" => "N/A"}}

    line = renderer.render(payload, cwd: Dir.mktmpdir("ws-nogit"))

    expect(line).not_to include("0% ctx")
  end

  # U5b: same coercion also accepts an out-of-range percentage (150, or
  # negative) and renders it verbatim as if it were a real, sane reading --
  # "150% ctx" is never a valid context-window usage and should not be
  # printed as though it is.
  it "U5b: does not render an out-of-range used_percentage (150) verbatim" do
    renderer = Workspace::StatuslineRenderer.new
    payload = {"model" => {"display_name" => "Sonnet"}, "context_window" => {"used_percentage" => 150}}

    line = renderer.render(payload, cwd: Dir.mktmpdir("ws-nogit"))

    expect(line).not_to include("150% ctx")
  end

  # U6: Statusline#record_reading forwards whatever
  # `context_window.used_percentage` Claude sends straight to
  # ContextStore#record with no type/range check. ContextStore#record then
  # coerces via `pct.to_i`, so garbage input ("N/A", negative, >100, NaN)
  # is silently recorded as a plausible-looking number instead of being
  # rejected -- `sessions --json`'s context_pct then reports a fabricated
  # reading with no way to tell it apart from a real one.
  it "U6: does not record a non-numeric used_percentage as a fabricated number" do
    dir = Dir.mktmpdir("ws-context-store")
    context_store = Workspace::ContextStore.new(path: File.join(dir, "context.json"))
    project_settings = instance_double(Workspace::ProjectSettings, load_global: {})
    renderer = instance_double(Workspace::StatuslineRenderer, render: "line")
    input = StringIO.new(JSON.generate({"context_window" => {"used_percentage" => "N/A"}}))
    output = StringIO.new
    statusline = Workspace::Commands::Statusline.new(
      context_store: context_store, renderer: renderer, project_settings: project_settings,
      env: {"TMUX_PANE" => "%9"}, input: input, output: output
    )

    statusline.call

    reading = context_store.reading_for_pane("%9")
    expect(reading).to be_nil
  end
end
