#!/usr/bin/env ruby
require 'stringio'
require_relative 'prune_releases'

class MockRetention < ReleaseRetention
  attr_reader :calls
  attr_accessor :runs, :releases, :restarted, :fail_releases

  def initialize(current_run: '2')
    super('test/trilium_ios', current_run: current_run)
    @calls = []
    @runs = (1..7).map do |id|
      {'id' => id, 'run_number' => id, 'created_at' => "2026-10-#{id.to_s.rjust(2, '0')}T00:00:00Z",
       'status' => id == 3 ? 'in_progress' : 'completed'}
    end
    @releases = (1..6).map do |id|
      {'id' => id, 'tag_name' => "build-#{id}-aaaaaaaaaaaa", 'draft' => id == 4,
       'created_at' => '2026-01-01T00:00:00Z', 'published_at' => "2026-10-#{id.to_s.rjust(2, '0')}T00:00:00Z",
       'assets' => [{'name' => id == 6 ? 'other.zip' : "TriliumPocket-build-#{id}-unsigned.ipa"}]}
    end
    @restarted = []
  end

  def api(endpoint, method: 'GET', paginate: false)
    @calls << [endpoint, method, paginate]
    return if method == 'DELETE'
    if endpoint.include?('/actions/workflows/')
      raise 'Run listing must paginate' unless paginate
      return @runs.reverse.each_slice(3).map { |page| {'workflow_runs' => page} }
    end
    if endpoint.end_with?('/releases?per_page=100')
      raise 'Release listing failed' if @fail_releases
      raise 'Release listing must paginate' unless paginate
      return @releases.reverse.each_slice(2).to_a
    end
    {'status' => @restarted.include?(endpoint.split('/').last.to_i) ? 'in_progress' : 'completed'}
  end
end

def assert(condition, message)
  raise message unless condition
end

retention = MockRetention.new
plan = retention.plan
assert(plan.map { |item| item.fetch(:endpoint) } == [
  'repos/test/trilium_ios/actions/runs/4', 'repos/test/trilium_ios/actions/runs/1',
  'repos/test/trilium_ios/releases/2', 'repos/test/trilium_ios/releases/1'
], 'Incorrect keep-three plan, pagination, current-run protection, or active-run protection')

original_stdout = $stdout
begin
  $stdout = StringIO.new
  retention.execute(plan)
  assert(retention.calls.none? { |call| call[1] == 'DELETE' }, 'Preview deleted remote resources')
  retention.restarted = [4]
  retention.execute(plan, apply: true)
  deletions = retention.calls.select { |call| call[1] == 'DELETE' }.map(&:first)
  assert(deletions == plan.drop(1).map { |item| item.fetch(:endpoint) }, 'Restarted run was deleted or cleanup was incomplete')
  assert(deletions.none? { |endpoint| endpoint.include?('/git/') }, 'Cleanup deleted Git tags')
ensure
  $stdout = original_stdout
end

retention = MockRetention.new(current_run: '')
assert(retention.plan(include_releases: false).all? { |item| item.fetch(:run) }, 'Run-only cleanup selected releases')
assert(retention.calls.none? { |call| call[0].include?('/releases') }, 'Run-only cleanup fetched releases')
retention.runs = retention.runs.last(3)
retention.releases = retention.releases.first(3)
assert(retention.plan.empty?, 'Three existing versions should all be retained')
retention.runs = []
retention.releases = []
assert(retention.plan.empty?, 'Empty repository should need no cleanup')

retention = MockRetention.new
retention.fail_releases = true
begin
  retention.plan
  raise 'API failure was ignored'
rescue RuntimeError => error
  raise unless error.message == 'Release listing failed'
end
assert(retention.calls.none? { |call| call[1] == 'DELETE' }, 'Incomplete listing caused deletion')

puts 'Release retention checks passed: keep-three pagination, active/current runs, preview, reruns, drafts, unrelated assets, run-only cleanup, and API failure.'
