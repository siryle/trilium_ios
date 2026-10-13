#!/usr/bin/env ruby
# Exercise release decisions and publication with local CLI mocks; no network or Xcode.
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
workflow = YAML.safe_load(File.read(File.join(root, '.github/workflows/ios-release.yml')))
resolve = workflow.fetch('jobs').fetch('resolve').fetch('steps').find { |step| step['id'] == 'source' }.fetch('run')
publish = workflow.fetch('jobs').fetch('publish').fetch('steps').find { |step| step['run'] }.fetch('run')
workflow.fetch('jobs').each_value do |job|
  job.fetch('steps').each do |step|
    next unless step['run']
    _, error, status = Open3.capture3('bash', '-n', stdin_data: step['run'])
    raise error unless status.success?
  end
end

Dir.mktmpdir('trilium-release-check-') do |directory|
  bin = File.join(directory, 'bin')
  FileUtils.mkdir_p(bin)
  mocks = {
    'git' => <<~'SH',
      #!/bin/bash
      set -eu
      if [[ "$1" == rev-parse ]]; then printf '%s\n' "$MOCK_SHA"; fi
    SH
    'gh' => <<~'SH',
      #!/bin/bash
      set -eu
      printf '%s\n' "$*" >> "$MOCK_CALLS"
      if [[ "$1" == api ]]; then printf 'commit\t%s\n' "${MOCK_REMOTE_SHA:-$MOCK_SHA}"; fi
      if [[ "$1" == release && "$2" == view ]]; then exit 1; fi
    SH
    'sha256sum' => <<~'SH'
      #!/bin/bash
      exec shasum -a 256 "$@"
    SH
  }
  mocks.each do |name, script|
    path = File.join(bin, name)
    File.write(path, script)
    File.chmod(0755, path)
  end
  sha = 'a' * 40
  output = File.join(directory, 'output')
  summary = File.join(directory, 'summary')
  calls = File.join(directory, 'calls')
  env = {'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'MOCK_SHA' => sha, 'MOCK_CALLS' => calls,
         'EVENT_SHA' => sha, 'RUN_NUMBER' => '42', 'GITHUB_OUTPUT' => output, 'GITHUB_STEP_SUMMARY' => summary}
  cases = [
    ['main push', 'push', 'branch', 'main', '', true, true, "build-42-#{sha[0, 12]}"],
    ['PR', 'pull_request', 'branch', '42/merge', '', false, false, ''],
    ['manual build', 'workflow_dispatch', 'branch', 'main', '', true, true, "build-42-#{sha[0, 12]}"],
    ['version push', 'push', 'tag', 'v1.0.0', '', true, false, 'v1.0.0'],
    ['manual version', 'workflow_dispatch', 'branch', 'main', 'v1.0.0', true, false, 'v1.0.0'],
    ['other branch', 'push', 'branch', 'feature', '', false, false, '']
  ]
  cases.each do |name, event, type, ref, tag, release, prerelease, expected_tag|
    File.write(output, '')
    _, error, status = Open3.capture3(env.merge('EVENT_NAME' => event, 'REF_TYPE' => type,
                                               'REF_NAME' => ref, 'REQUESTED_TAG' => tag), 'bash', '-c', resolve)
    raise "#{name}: #{error}" unless status.success?
    values = File.readlines(output, chomp: true).map { |line| line.split('=', 2) }.to_h
    expected = {'sha' => sha, 'tag' => expected_tag, 'release' => release.to_s, 'prerelease' => prerelease.to_s}
    raise "#{name}: unexpected #{values}" unless values == expected
  end
  _, _, status = Open3.capture3(env.merge('EVENT_NAME' => 'workflow_dispatch', 'REF_TYPE' => 'branch',
                                         'REF_NAME' => 'main', 'REQUESTED_TAG' => 'v1.0.0;echo bad'), 'bash', '-c', resolve)
  raise 'Invalid version tag accepted' if status.success?

  packages = File.join(directory, 'release')
  FileUtils.mkdir_p(packages)
  File.write(File.join(packages, 'COMMIT_SHA.txt'), "#{sha}\n")
  sum, _, status = Open3.capture3('shasum', '-a', '256', 'COMMIT_SHA.txt', chdir: packages)
  raise 'Could not generate checksum fixture' unless status.success?
  File.write(File.join(packages, 'SHA256SUMS.txt'), sum)
  [true, false].each do |prerelease|
    File.write(calls, '')
    tag = prerelease ? "build-42-#{sha[0, 12]}" : 'v1.0.0'
    _, error, status = Open3.capture3(env.merge('GH_REPO' => 'test/trilium_ios', 'RELEASE_TAG' => tag,
                                               'TESTED_SHA' => sha, 'IS_PRERELEASE' => prerelease.to_s),
                                     'bash', '-c', publish, chdir: directory)
    raise "Publication failed: #{error}" unless status.success?
    commands = File.read(calls)
    raise 'Missing upload' unless commands.include?("release upload #{tag}")
    raise 'Missing immutable target' unless commands.include?("--target #{sha}")
    flag = prerelease ? '--prerelease --latest=false' : '--verify-tag'
    raise 'Incorrect release type' unless commands.include?(flag)
  end
  File.write(calls, '')
  _, _, status = Open3.capture3(env.merge('GH_REPO' => 'test/trilium_ios', 'RELEASE_TAG' => 'v1.0.0',
                                         'TESTED_SHA' => sha, 'IS_PRERELEASE' => 'false', 'MOCK_REMOTE_SHA' => 'b' * 40),
                               'bash', '-c', publish, chdir: directory)
  raise 'Moved tag allowed upload' if status.success? || File.read(calls).include?('release upload')
  puts 'Release workflow checks passed: 6 trigger cases, invalid tag rejection, prerelease/version upload, moved tag rejection.'
end
