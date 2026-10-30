require "spec_helper"
require "tmpdir"
require "timeout"

RSpec.describe Workspace::WorkflowGateNote do
  around do |example|
    Dir.mktmpdir("wf-gate-note") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:artifacts) { File.join(@dir, "artifacts") }
  let(:notes_dir) { File.join(@dir, "notes") }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => notes_dir}) }
  let(:produces) { ["triage.md"] }
  let(:run) do
    {"id" => "wr_1", "workspace" => "app", "current" => "triage", "artifacts_dir" => artifacts,
     "definition" => {"steps" => [{"id" => "triage", "produces" => produces}]},
     "steps" => {"triage" => {"state" => "passed", "attempts" => [{"n" => 1}, {"n" => 2}]}}}
  end
  subject(:gate_note) { described_class.new(notes: notes) }

  before do
    FileUtils.mkdir_p([artifacts, notes_dir])
    File.write(File.join(notes_dir, "n.md"), "note body")
  end

  def first_file(text)
    File.write(File.join(artifacts, "triage.md"), text)
  end

  it "reads the name from the first line only, with a CRLF ending" do
    first_file("note: n.md\r\ncounts\n")

    expect(gate_note.find(run)).to eq("name" => "n.md", "path" => File.join(notes_dir, "n.md"), "sha256" => Digest::SHA256.hexdigest("note body"))
  end

  it "names no note for a note: line that is not first, a missing first file, or a step that produces nothing" do
    first_file("counts\nnote: n.md\n")
    expect(gate_note.find(run)).to be_nil

    File.delete(File.join(artifacts, "triage.md"))
    expect(gate_note.find(run)).to be_nil

    produces.clear
    expect(gate_note.find(run)).to be_nil
  end

  it "refuses a directory, and a workspace whose notes directory can't be found, as gate_note_unreadable" do
    FileUtils.mkdir_p(File.join(notes_dir, "dir.md"))
    first_file("note: dir.md\n")
    expect { gate_note.find(run) }.to raise_error(Workspace::Error) { |error|
      expect(error.code).to eq("gate_note_unreadable")
      expect(error.details).to include("attempt" => 2, "name" => "dir.md")
    }

    first_file("note: n.md\n")
    allow(notes).to receive(:info).and_raise(Workspace::Error.new("Unknown workspace 'app'.", code: "unknown_workspace"))
    expect { gate_note.find(run) }.to raise_error(Workspace::Error, /the notes directory of app can't be found/) { |error|
      expect(error.code).to eq("gate_note_unreadable")
    }
  end

  it "names no note for a first file that is a FIFO or a link, without waiting on it" do
    path = File.join(artifacts, "triage.md")
    File.mkfifo(path)
    expect(Timeout.timeout(5) { gate_note.find(run) }).to be_nil

    File.delete(path)
    File.write(File.join(artifacts, "real.md"), "note: n.md\n")
    File.symlink(File.join(artifacts, "real.md"), path)
    expect(gate_note.find(run)).to be_nil
  end

  it "refuses a note: line that is not UTF-8 text, or is cut inside a character at the read limit, as gate_note_unreadable" do
    first_file("note: n\xC3.md\n".b)
    expect { gate_note.find(run) }.to raise_error(Workspace::Error, /is not UTF-8 text/) { |error| expect(error.code).to eq("gate_note_unreadable") }

    first_file("note: x#{"é" * 3000}.md\n")
    expect { gate_note.find(run) }.to raise_error(Workspace::Error, /is not UTF-8 text/) { |error| expect(error.code).to eq("gate_note_unreadable") }

    # A first line that names no note is not checked, however long: a gate on another kind of file approves as before.
    first_file("#{"é" * 3000}\n")
    expect(gate_note.find(run)).to be_nil
  end

  it "hashes nothing that is not a regular file" do
    File.symlink(File.join(notes_dir, "n.md"), File.join(notes_dir, "link.md"))

    expect(described_class.sha256(File.join(notes_dir, "link.md"))).to be_nil
    expect(described_class.sha256(notes_dir)).to be_nil
    expect(described_class.sha256(File.join(notes_dir, "gone.md"))).to be_nil
  end
end
