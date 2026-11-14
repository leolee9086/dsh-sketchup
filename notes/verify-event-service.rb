# encoding: UTF-8
# 在真实 SketchUp 中验证事件投递；只读模型，不创建/删除几何。
require 'json'
require 'time'
require File.join(__dir__, '..', 'ruby', 'dsh_sketchup_bridge', 'event_service')
module DSHEventServiceVerification
  extend self
  def run(report_path)
    raise 'Verification already running' if @running
    @running = true
    @report_path = report_path
    @received = []
    @failures = []
    @main = Thread.main
    @model = Sketchup.active_model
    @service = DSHSketchupBridge::EventService.attach('verification')
    # 只有实际消息到达才预约一次原生唤醒。共96项，跨越调度器的32项批界。
    @sender = Thread.new do
      96.times do |i|
        @service.post do
          @failures << "callback #{i} used another thread" unless Thread.current == @main
          @failures << "callback #{i} changed model" unless Sketchup.active_model == @model
          @received << i
          finish if i == 95
        end
      end
    rescue => error
      @failures << "sender: #{error.class}: #{error.message}"
      @service.post { finish }
    end
    {started: true, report: report_path}
  end

  def finish
    expected = (0...96).to_a
    @failures << 'messages lost or reordered' unless @received == expected
    stats = @service.stats
    @service.detach('verification')
    @running = false
    File.write(@report_path, JSON.pretty_generate({at: Time.now.iso8601,received: @received.length,failures: @failures,stats: stats,modelChanged: Sketchup.active_model != @model}) + "\n")
  end
end
DSHEventServiceVerification.run(File.join(__dir__, 'event-service-verification.json'))
