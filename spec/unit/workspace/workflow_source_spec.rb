require "spec_helper"

RSpec.describe Workspace::WorkflowSource do
  def parse(entry) = described_class.parse(entry, home: "/home/me")

  it "reads a tree URL with a ref" do
    s = parse("https://github.com/acme/flows/tree/main/team/workflows")
    expect([s.kind, s.owner, s.repo, s.ref, s.path]).to eq([:github, "acme", "flows", "main", "team/workflows"])
    expect(s).to be_frozen
  end

  it "lists every ref/path split of a tree URL, shortest ref first" do
    s = parse("https://github.com/acme/flows/tree/me/topic/team/workflows")
    expect([s.ref, s.path]).to eq(["me", "topic/team/workflows"])
    expect(s.splits).to eq([["me", "topic/team/workflows"], ["me/topic", "team/workflows"], ["me/topic/team", "workflows"]])
  end

  it "has no splits outside a tree URL" do
    expect(parse("acme/flows/a/b").splits).to be_nil
  end

  it "reads a URL without tree as the default branch" do
    s = parse("https://github.com/acme/flows/workflows")
    expect([s.kind, s.owner, s.repo, s.ref, s.path]).to eq([:github, "acme", "flows", nil, "workflows"])
  end

  it "reads the o/r/path shorthand as the default branch" do
    s = parse("acme/flows/a/b")
    expect([s.kind, s.owner, s.repo, s.ref, s.path]).to eq([:github, "acme", "flows", nil, "a/b"])
  end

  it "keeps an absolute path local" do
    s = parse("/srv/flows")
    expect([s.kind, s.path]).to eq([:local, "/srv/flows"])
  end

  it "expands ~ in a local path" do
    expect(parse("~/flows").path).to eq("/home/me/flows")
  end

  it "refuses a non-github URL" do
    expect { parse("https://gitlab.com/a/b/c") }.to raise_error(Workspace::UsageError, /not a github.com URL/)
    expect { parse("http://github.com/a/b/c") }.to raise_error(Workspace::UsageError, /not a github.com URL/)
  end

  it "refuses an entry with no owner or repository" do
    expect { parse("flows") }.to raise_error(Workspace::UsageError, /owner and repository/)
    expect { parse("https://github.com/acme") }.to raise_error(Workspace::UsageError, /owner and repository/)
  end

  it "refuses an empty path" do
    expect { parse("acme/flows") }.to raise_error(Workspace::UsageError, /empty path/)
    expect { parse("https://github.com/acme/flows/tree/main") }.to raise_error(Workspace::UsageError, /empty path/)
  end

  it "refuses tree with no ref and .. segments" do
    expect { parse("https://github.com/acme/flows/tree") }.to raise_error(Workspace::UsageError, /no ref/)
    expect { parse("acme/flows/../x") }.to raise_error(Workspace::UsageError, /\.\./)
  end

  it "refuses a blank or non-string entry" do
    expect { parse("") }.to raise_error(Workspace::UsageError)
    expect { parse(nil) }.to raise_error(Workspace::UsageError)
  end
end
