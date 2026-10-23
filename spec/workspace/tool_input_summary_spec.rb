RSpec.describe Workspace::ToolInputSummary do
  def summary(tool, input)
    described_class.call(tool, input)
  end

  it "takes the first non-empty line of a Bash command" do
    expect(summary("Bash", {"command" => "\n  bundle exec rspec\nrm -rf /tmp/x"})).to eq("bundle exec rspec")
  end

  it "takes the file of each file tool" do
    %w[Edit Write Read MultiEdit].each do |tool|
      expect(summary(tool, {"file_path" => "/a/b.rb", "content" => "SECRET body", "new_string" => "SECRET"})).to eq("/a/b.rb")
    end
    expect(summary("NotebookEdit", {"notebook_path" => "/a/n.ipynb", "new_source" => "SECRET"})).to eq("/a/n.ipynb")
  end

  it "takes a Grep or Glob pattern, with the path when it is short" do
    expect(summary("Grep", {"pattern" => "todo", "path" => "lib"})).to eq("todo (in lib)")
    expect(summary("Glob", {"pattern" => "**/*.rb"})).to eq("**/*.rb")
    expect(summary("Grep", {"pattern" => "todo", "path" => "p" * 81})).to eq("todo")
  end

  it "takes a WebFetch url" do
    expect(summary("WebFetch", {"url" => "https://example.com", "prompt" => "SECRET"})).to eq("https://example.com")
  end

  it "has no summary for other tools, a missing field, or input that is not a hash" do
    expect(summary("Task", {"prompt" => "x", "description" => "y"})).to be_nil
    expect(summary("Bash", {})).to be_nil
    expect(summary("Bash", {"command" => 5})).to be_nil
    expect(summary("Bash", "ls")).to be_nil
    expect(summary(nil, {"command" => "ls"})).to be_nil
  end

  it "blanks control characters" do
    result = summary("Bash", {"command" => "echo\e[31mred\e[0m\tdone\r"})

    expect(result).to eq("echo [31mred [0m done")
    expect(summary("Read", {"file_path" => "a\nb\e.rb"})).to eq("a b .rb")
  end

  it "blanks likely secrets: NAME=value, Bearer tokens and URL passwords" do
    expect(summary("Bash", {"command" => "API_TOKEN=abc123 curl -H 'Authorization: Bearer xyz' https://u:pw@h/x"}))
      .to eq("API_TOKEN=[redacted] curl -H 'Authorization: Bearer [redacted]' https://u:[redacted]@h/x")
    expect(summary("Bash", {"command" => "FOO=bar make"})).to eq("FOO=bar make")
  end

  it "leaves a summary of exactly 300 bytes alone" do
    command = "a" * 300
    expect(summary("Bash", {"command" => command})).to eq(command)
  end

  it "cuts a longer one to 300 bytes including a trailing ellipsis" do
    result = summary("Bash", {"command" => "a" * 500})

    expect(result.bytesize).to eq(300)
    expect(result).to end_with("…")
    expect(result).to eq("#{"a" * 297}…")
  end

  it "cuts on a UTF-8 character boundary" do
    result = summary("Bash", {"command" => "é" * 400})

    expect(result).to be_valid_encoding
    expect(result.bytesize).to be <= 300
    expect(result).to eq("#{"é" * 148}…")
  end

  it "replaces invalid bytes rather than raising" do
    expect(summary("Bash", {"command" => (+"ls \xFF").force_encoding("UTF-8")})).to be_valid_encoding
  end

  describe ".cap" do
    it "returns nil for non-strings and blank text" do
      expect(described_class.cap(nil)).to be_nil
      expect(described_class.cap(" \n ")).to be_nil
    end
  end
end
