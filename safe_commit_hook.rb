#!/usr/bin/env ruby

class SafeCommitHook
  require 'json'
  WHITELIST_NAME = '.ignored_security_risks'

  def initialize(stdout)
    $stdout = stdout
    @errors = []
  end

  def run(repo_full_path, check_all_commits, check_patterns_file)
    check(check_all_commits, check_patterns(check_patterns_file), repo_full_path, whitelisted_files)
    print_errors_and_exit
  end

  private

  def check(check_all_commits, check_patterns, repo_full_path, whitelist)
    if check_all_commits
      check_all_commits(check_patterns, repo_full_path, whitelist)
    end
    check_files(check_patterns, get_staged_file_basenames(repo_full_path, whitelist), 'currently staged files')
  end

  def check_all_commits(check_patterns, repo_full_path, whitelist)
    commit_hashes = `cd #{repo_full_path} && git log --pretty=format:%h 2>/dev/null`.split # swallow no-commits-yet error
    commit_hashes.each { |commit_hash|
      files = `cd #{repo_full_path} && git show --pretty="" --name-only -r #{commit_hash}`.split
      check_files(check_patterns, basenames(files, whitelist), commit_hash)
    }
  end

  def check_files(check_patterns, file_basenames, commit_hash)
    check_patterns.each do |check_pattern|
      case check_pattern['part']
        when 'filename'
          check_filename_pattern(check_pattern, commit_hash, file_basenames)
        when 'extension'
          check_extension_pattern(check_pattern, commit_hash, file_basenames)
        when 'path'
          check_path_pattern(check_pattern, commit_hash, file_basenames)
        else
          p "invalid part of check pattern: #{check_pattern}"
      end
    end
  end

  def check_path_pattern(check_pattern, commit_hash, file_basenames)
    file_basenames.each { |filepath, _|
      escaped_pattern = check_pattern['pattern'].gsub('\\', '\\\\')
      if found_match(File.dirname(filepath) =~ Regexp.new(escaped_pattern))
        add_errors(check_pattern, filepath, commit_hash)
      end
    }
  end

  def found_match(match_result)
    match_result == 0
  end

  def check_extension_pattern(check_pattern, commit_hash, file_basenames)
    file_basenames.each { |filepath, basename|
      if File.extname(basename).gsub('.', '') == check_pattern['pattern'] # this might have to get fancier for regexen
        add_errors(check_pattern, filepath, commit_hash)
      end
    }
  end

  def check_filename_pattern(check_pattern, commit_hash, file_basenames)
    file_basenames.each { |filepath, basename|
      if found_match(basename =~ Regexp.new(check_pattern['pattern']))
        add_errors(check_pattern, filepath, commit_hash)
      end
    }
  end

  def check_patterns(check_patterns_file)
    JSON.parse(File.read(check_patterns_file))
  end

  def add_errors(cp, filepath, commit_hash)
    @errors << "#{cp['caption']} in commit #{commit_hash} in file #{filepath}"
  end

  def print_errors_and_exit
    if @errors.size > 0
      start_red = "\e[31m"
      end_color = "\e[0m"
      puts start_red
      puts '[ERROR] Unable to complete git commit.'
      puts 'See .git/hooks/pre-commit or https://github.com/compwron/safe-commit-hook-rb for details'
      puts 'Add full filepath to .ignored_security_risks to ignore'
      puts @errors
      puts end_color
      exit 1
    else
      print "safe-commit-hook check looks clean. See ignored files in #{WHITELIST_NAME}"
    end
  end

  def get_staged_file_basenames(repo_full_path, whitelist)
    files = `cd #{repo_full_path} && git diff --name-only --cached`.split("\n")
    basenames(files, whitelist)
  end

  def basenames(files, whitelist)
    files.inject({}) { |aggregator, filename|
      aggregator[filename] = File::basename(filename)
      aggregator
    }.reject { |filepath, _|
      is_git_file?(filepath) || whitelist.include?(filepath)
    }
  end

  def is_git_file?(filepath)
    filepath.split('/')[0] == '.git'
  end

  def whitelisted_files
    whitelists = Dir.glob('**/*', File::FNM_DOTMATCH).select { |f| f.include?(WHITELIST_NAME) }
    files = []
    if whitelists == []
      File.new(WHITELIST_NAME, 'w')
      whitelists << WHITELIST_NAME
    end
    whitelists.each { |w|
      files << IO.readlines(w).map(&:strip)
    }
    files.flatten
  end
end

if $PROGRAM_NAME == __FILE__
  check_all_commits = ENV['CHECK_ALL_COMMITS']
  check_patterns_file = ENV['GIT_DENY_PATTERNS'] || '.git/hooks/git-deny-patterns.json'
  SafeCommitHook.new(STDOUT).run(`pwd`.strip, check_all_commits, check_patterns_file)
end
