require 'spec_helper'

describe SafeCommitHook do
  subject { SafeCommitHook.new(captured_output).run(@repo_full_path, args, check_patterns) }
  let(:captured_output) { StringIO.new }
  let(:args) { [] }
  let(:check_patterns) { 'spec/empty.json' }

  let(:default_whitelist) { '.ignored_security_risks' }
  let(:whitelist) { "#{@repo_full_path}/.ignored_security_risks" }
  let(:gem_credential) { 'gem/credentials/something.txt' }
  let(:repo) { 'fake_git' }
  @g = nil # refresh git repo for each test
  @repo_full_path = nil # run every test in a different repo so that rspec-mutant can run in many forks

  before do
    FileUtils.rm_r(repo) if Dir.exists?(repo)
    FileUtils.mkdir(repo)
    @repo_full_path = `pwd`.strip + "/#{repo}/" + SecureRandom.uuid.to_s # run every test in a different repo so that rspec-mutant can run in many forks
    @g = Git.init(@repo_full_path)
    @g.config('user.name', 'safe-commit-hook-rb')
    @g.config('user.email', 'safe-commit-hook-rb@example.com')
  end

  after do
    FileUtils.rm_r(@repo_full_path)
  end

  def add_to_whitelist(filepath)
    File.open(whitelist, 'w') { |f| f.puts(filepath) }
    expect(IO.binread(whitelist)).to include(filepath)
  end

  def create_unstaged_file(filename)
    dir = File.dirname(filename)
    FileUtils.mkdir_p(dir)
    File.new(filename, 'w')
  end

  def create_staged_file(filename)
    full_filename = "#{@repo_full_path}/#{filename}"
    create_unstaged_file(full_filename)
    @g.add(filename)
  end

  def commit_file(filepath)
    create_staged_file(filepath)
    @g.commit('commit from test')
  end

  def commit_removal_of_file(filepath) # TODO what is even happening here
    full_filename = "#{@repo_full_path}/#{filename}"
    File.delete(full_filename)

    # TODO find out why the removal of this line does not make any tests fail
    # `cd #{@repo_full_path} && git add -A && git commit -m "commit from test - deletion"` # TODO use git gem in tests for better system compatibility
  end

  describe 'search all changed files for suspicious strings' do
    it 'finds password assignment'
    it 'finds high entrupy strings'
    it 'finds RSA key header'
  end

  describe 'when there are no bad files' do
    it 'outputs reassuring informational message' do
      subject
      expect(captured_output.string).to eq 'safe-commit-hook check looks clean. See ignored files in .ignored_security_risks'
    end
  end

  describe 'check every commit in history, even if the checked in files are gone now' do
    let(:args) { ['check_full'] }
    let(:check_patterns) { 'spec/file_removed_in_previous_commit.json' }
    # let(:check_patterns) { "spec/rsa.json" }
    let(:filename) { 'test_file_removed_in_previous_commit.txt' }

    it 'does not see file that has never been committed' do
      expect { subject }.to_not raise_error
    end

    it 'sees file that has been committed and is still present' do
      commit_file(filename)
      did_exit = false
      begin
        subject
      rescue SystemExit
        did_exit = true
      end
      expect(captured_output.string).to match /File removed in previous commit .* in file #{filename}/
      expect(did_exit).to be true
    end

    it 'sees file that has been committed and removed' do
      commit_file(filename)
      commit_removal_of_file(filename)
      did_exit = false
      begin
        subject
      rescue SystemExit
        did_exit = true
      end
      expect(captured_output.string).to match /File removed in previous commit .* in file #{filename}/
      expect(did_exit).to be true
    end
  end

  describe 'with no committed passwords' do
    it 'detects no false positives' do
      create_staged_file('ok_file.txt')
      expect { subject }.to_not raise_error
    end
  end

  describe 'with missing whitelist' do
    it 'does not error when whitelist is missing' do
      FileUtils.rm_f(whitelist)
      expect { subject }.to_not raise_error
    end
  end

  describe 'with check patterns including filename rsa' do
    let(:check_patterns) { 'spec/rsa.json' }
    describe 'with filename including rsa' do

      it 'returns with exit 1 and prints error' do
        create_staged_file('id_rsa')
        did_exit = false
        begin
          subject
        rescue SystemExit
          did_exit = true
        end
        expect(captured_output.string).to match /Private SSH key .* in file .*id_rsa/
        expect(did_exit).to be true
      end
    end
  end

  describe 'with regex check pattern for all filenames' do
    let(:check_patterns) { 'spec/everything.json' }

    it 'checks only files that are currently staged' do
      create_unstaged_file("#{repo}/file1.txt")
      create_staged_file('file2.txt')
      begin
        subject
      rescue SystemExit
      end
      expect(captured_output.string).to match /file2.txt/
      expect(captured_output.string).to_not match /file1.txt/
    end

    it 'detects file with a name that matches the regex' do
      create_staged_file('literally-anything')
      did_exit = false
      begin
        subject
      rescue SystemExit
        did_exit = true
      end
      expect(captured_output.string).to match /Detected literally everything!/
      expect(did_exit).to be true
    end

    it 'accepts whitelisting' do
      ignored_file = 'ignored_file.txt'
      create_staged_file(ignored_file)
      add_to_whitelist(ignored_file)
      begin
        subject
      rescue SystemExit
      end
      expect(captured_output.string).to_not match /ignored_file/
    end

    it 'always ignores .git' do
      begin
        subject
      rescue SystemExit
      end
      expect(captured_output.string).to_not match /^A\.git\//
    end
  end

  describe 'with extensions check pattern' do
    let(:check_patterns) { 'spec/pem_extension.json' }
    it 'detects file with bad file ending' do
      create_staged_file('probably_bad.pem')
      did_exit = false
      begin
        subject
      rescue SystemExit
        did_exit = true
      end
      expect(captured_output.string).to match /Potential cryptographic private key .* in file .*probably_bad.pem/
      expect(did_exit).to be true
    end

    it 'does not detect file with file ending in its name but not actually a bad file ending' do
      create_staged_file('pem.notpem')
      expect { subject }.to_not raise_error
    end
  end

  describe 'with path check pattern' do
    let(:check_patterns) { 'spec/path.json' }

    it 'does not falsely detect' do
      create_staged_file('gem/foo/credentials/something.txt')
      expect { subject }.to_not raise_error
    end

    context 'with bad path' do
      it 'detects bad path' do
        create_staged_file(gem_credential)
        did_exit = false
        begin
          subject
        rescue SystemExit
          did_exit = true
        end
        expect(captured_output.string).to match /Rubygems credentials file .* in file gem\/credentials\/something.txt/
        expect(did_exit).to be true
      end
    end
  end
end
