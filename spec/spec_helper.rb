require 'rack/protection'
require 'rack/test'
require 'rack'
require 'forwardable'
require 'stringio'

if defined? Gem.loaded_specs and Gem.loaded_specs.include? 'rack'
  version = Gem.loaded_specs['rack'].version.to_s
else
  version = Rack.release + '.0'
end

if version == "1.3"
  Rack::Session::Abstract::ID.class_eval do
    private
    def prepare_session(env)
      session_was                  = env[ENV_SESSION_KEY]
      env[ENV_SESSION_KEY]         = SessionHash.new(self, env)
      env[ENV_SESSION_OPTIONS_KEY] = OptionsHash.new(self, env, @default_options)
      env[ENV_SESSION_KEY].merge! session_was if session_was
    end
  end
end

unless Rack::MockResponse.method_defined? :header
  Rack::MockResponse.send(:alias_method, :header, :headers)
end

module DummyApp
  def self.call(env)
    Thread.current[:last_env] = env
    body = (env['REQUEST_METHOD'] == 'HEAD' ? '' : 'ok')
    [200, {'Content-Type' => env['wants'] || 'text/plain'}, [body]]
  end
end

module TestHelpers
  extend Forwardable
  def_delegators :last_response, :body, :headers, :status, :errors
  def_delegators :current_session, :env_for
  attr_writer :app

  def app
    @app ||= nil
    @app || mock_app(DummyApp)
  end

  def mock_app(app = nil, &block)
    app = block if app.nil? and block.arity == 1
    if app
      klass = described_class
      mock_app do
        use Rack::Head
        use(Rack::Config) { |e| e['rack.session'] ||= {}}
        use klass
        run app
      end
    else
      @app = Rack::Lint.new Rack::Builder.new(&block).to_app
    end
  end

  def with_headers(headers)
    proc { [200, {'Content-Type' => 'text/plain'}.merge(headers), ['ok']] }
  end

  def env
    Thread.current[:last_env]
  end
end

# see http://blog.101ideas.cz/posts/pending-examples-via-not-implemented-error-in-rspec.html
module NotImplementedAsPending
  def self.included(base)
    base.class_eval do
      alias_method :__finish__, :finish
      remove_method :finish
    end
  end

  def finish(reporter)
    if @exception.is_a?(NotImplementedError)
      from = @exception.backtrace[0]
      message = "#{@exception.message} (from #{from})"
      @pending_declared_in_example = message
      metadata[:pending] = true
      @exception = nil
    end

    __finish__(reporter)
  end

  RSpec::Core::Example.send :include, self
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.include Rack::Test::Methods
  config.include TestHelpers
end

shared_examples_for 'any rack application' do
  it "should not interfere with normal get requests" do
    expect(get('/')).to be_ok
    expect(body).to eq('ok')
  end

  it "should not interfere with normal head requests" do
    expect(head('/')).to be_ok
  end

  it 'should not leak changes to env' do
    klass    = described_class
    detector = Struct.new(:app) do
      def call(env)
        was = env.dup
        res = app.call(env)
        was.each do |k,v|
          next if env[k] == v
          fail "env[#{k.inspect}] changed from #{v.inspect} to #{env[k].inspect}"
        end
        res
      end
    end

    mock_app do
      use Rack::Head
      use(Rack::Config) { |e| e['rack.session'] ||= {}}
      use detector
      use klass
      run DummyApp
    end

    expect(get('/..', :foo => '<bar>')).to be_ok
  end

  it 'allows passing on values in env' do
    klass    = described_class
    changer  = Struct.new(:app) do
      def call(env)
        env['foo.bar'] = 42
        app.call(env)
      end
    end
    detector = Struct.new(:app) do
      def call(env)
        app.call(env)
      end
    end

    expect_any_instance_of(detector).to receive(:call).with(
      hash_including('foo.bar' => 42)
    ).and_call_original

    mock_app do
      use Rack::Head
      use(Rack::Config) { |e| e['rack.session'] ||= {}}
      use changer
      use klass
      use detector
      run DummyApp
    end

    expect(get('/')).to be_ok
  end
end
