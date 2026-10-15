#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'optparse'

class ReleaseRetention
  KEEP = 3

  def initialize(repository, current_run: ENV['GITHUB_RUN_ID'])
    raise 'Expected GH_REPO in owner/repository format' unless repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)

    @base = "repos/#{repository}"
    @current_run = current_run.to_s
  end

  def api(endpoint, method: 'GET', paginate: false)
    command = ['gh', 'api', '--method', method]
    command.concat(['--paginate', '--slurp']) if paginate
    output, error, status = Open3.capture3(*command, endpoint)
    raise "GitHub API #{method} #{endpoint} failed: #{error}" unless status.success?

    output.strip.empty? ? nil : JSON.parse(output)
  end

  def plan(include_releases: true)
    pages = api("#{@base}/actions/workflows/ios-release.yml/runs?per_page=100", paginate: true)
    runs = pages.flat_map { |page| page.fetch('workflow_runs') }
    operations = oldest(runs, 'created_at').select do |run|
      run.fetch('status') == 'completed' && run.fetch('id').to_s != @current_run
    end.map do |run|
      {endpoint: "#{@base}/actions/runs/#{run.fetch('id')}",
       label: "workflow run ##{run.fetch('run_number')}", run: true}
    end
    if include_releases
      releases = api("#{@base}/releases?per_page=100", paginate: true).flatten(1)
      packages = releases.select do |release|
        release.fetch('assets').any? { |asset| asset.fetch('name').match?(/\ATriliumPocket-.+-unsigned\.ipa\z/) }
      end
      oldest(packages, 'published_at').each do |release|
        operations << {endpoint: "#{@base}/releases/#{release.fetch('id')}",
                       label: "release #{release.fetch('tag_name')}", run: false}
      end
    end
    operations
  end

  def execute(operations, apply: false)
    operations.each do |operation|
      puts "#{apply ? 'Delete' : 'Would delete'} #{operation.fetch(:label)}"
      next unless apply

      # A historical run may have been restarted after the listing was fetched.
      if operation.fetch(:run) && api(operation.fetch(:endpoint)).fetch('status') != 'completed'
        puts 'Skipped: workflow run is no longer completed'
        next
      end
      api(operation.fetch(:endpoint), method: 'DELETE')
    end
    puts "#{apply ? 'Cleanup' : 'Preview'} complete: #{operations.length} historical entries selected."
  end

  private

  def oldest(items, date)
    items.sort_by { |item| [item[date] || item.fetch('created_at'), item.fetch('id')] }.reverse.drop(KEEP)
  end
end

if $PROGRAM_NAME == __FILE__
  options = {apply: false, include_releases: true}
  OptionParser.new do |parser|
    parser.on('--apply', 'Delete historical workflow runs and IPA releases') { options[:apply] = true }
    parser.on('--skip-releases', 'Only prune workflow runs') { options[:include_releases] = false }
  end.parse!
  retention = ReleaseRetention.new(ENV.fetch('GH_REPO'))
  retention.execute(retention.plan(include_releases: options[:include_releases]), apply: options[:apply])
end
