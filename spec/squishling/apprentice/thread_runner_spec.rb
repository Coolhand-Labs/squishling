# frozen_string_literal: true

require "logger"

RSpec.describe Squishling::Apprentice::ThreadRunner do
  let(:io) { StringIO.new }
  let(:gate) { Queue.new }

  before { Squishling.configure { |c| c.logger = Logger.new(io) } }

  after { gate.close }

  it "runs jobs off the caller's thread, and drains" do
    runner = described_class.new
    threads = Queue.new

    expect(runner.call(-> { threads << Thread.current })).to be(true)
    expect(runner.drain(timeout: 5)).to be(true)

    thread = threads.pop
    expect(thread).not_to equal(Thread.current)
    expect(thread.name).to eq("squishling-apprentice")
    expect(runner.pending).to eq(0)
  end

  it "drops a job beyond max_queue pending runs, and logs it" do
    runner = described_class.new(size: 1, max_queue: 1)
    blocked = gate

    expect(runner.call(-> { blocked.pop })).to be(true)
    expect(runner.call(-> {})).to be(false)

    expect(runner.pending).to eq(1)
    expect(io.string).to include("apprentice run dropped: 1 runs already pending")
    expect(runner.drain(timeout: 0.05)).to be(false)
    gate << :go
    expect(runner.drain(timeout: 5)).to be(true)
  end

  it "keeps working after a job raises, and logs it" do
    runner = described_class.new(size: 1)
    ran = Queue.new

    runner.call(-> { raise IOError, "stats down" })
    runner.call(-> { ran << :second })
    runner.drain(timeout: 5)

    expect(ran.pop).to eq(:second)
    expect(io.string).to include("apprentice run failed: IOError")
    expect(io.string).not_to include("stats down")
  end

  it "counts a job that raises a non-StandardError as finished" do
    runner = described_class.new(size: 1)

    runner.call(-> { raise NotImplementedError, "todo" })

    expect(runner.drain(timeout: 5)).to be(true)
    expect(runner.pending).to eq(0)
    expect(io.string).to include("apprentice run failed: NotImplementedError")
  end

  it "doesn't count a run whose thread couldn't start" do
    runner = described_class.new(size: 1)
    allow(Thread).to receive(:new).and_raise(ThreadError, "can't create Thread")

    expect { runner.call(-> {}) }.to raise_error(ThreadError)
    expect(runner.pending).to eq(0)
  end

  it "starts afresh in a forked child, which inherits no threads" do
    runner = described_class.new(size: 1, max_queue: 1)
    blocked = gate
    runner.call(-> { blocked.pop })
    allow(Process).to receive(:pid).and_return(Process.pid + 1)

    expect(runner.pending).to eq(0)
    expect(runner.drain(timeout: 0)).to be(true)
    ran = Queue.new
    expect(runner.call(-> { ran << :child })).to be(true)
    expect(ran.pop).to eq(:child)
  end

  it "wraps each job in the Rails executor when there is one" do
    wrapped = Queue.new
    executor = Object.new.tap do |object|
      object.define_singleton_method(:wrap) do |&block|
        wrapped << :wrapped
        block.call
      end
    end
    application = Struct.new(:executor).new(executor)
    stub_const("Rails", Module.new { define_singleton_method(:application) { application } })
    runner = described_class.new

    ran = Queue.new
    runner.call(-> { ran << :job })
    runner.drain(timeout: 5)

    expect([wrapped.pop, ran.pop]).to eq(%i[wrapped job])
  end

  it "takes a positive size and max_queue" do
    expect { described_class.new(size: 0) }
      .to raise_error(Squishling::ConfigurationError, /size: must be a positive Integer, got 0/)
    expect { described_class.new(max_queue: "10") }
      .to raise_error(Squishling::ConfigurationError, /max_queue: must be a positive Integer/)
  end

  it "can be configured as the runner itself" do
    runner = described_class.new(size: 1)
    Squishling.configure { |c| c.apprentice_runner = runner }

    expect(Squishling::Apprentice.runner).to equal(runner)
    expect(Squishling::Apprentice.drain(timeout: 1)).to be(true)
  end
end
