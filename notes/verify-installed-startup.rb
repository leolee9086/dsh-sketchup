# encoding: UTF-8
# 只观察正式安装的扩展，不 load 工作区实现，也不修改模型。
require 'json'
require 'time'
module DSHInstalledStartupVerification
  REPORT = File.join(__dir__, 'installed-startup-verification.json')
  def self.record(phase, error = nil)
    service = defined?(DSHSketchupBridge::EventService) && DSHSketchupBridge::EventService
    proxy = defined?(ZhiD5LocalProxy) && ZhiD5LocalProxy
    state = proxy && proxy.ui_state
    value = {at:Time.now.iso8601,pid:Process.pid,phase:phase,error:error,model:Sketchup.active_model.path,
      managerDefined:DSHSketchupBridge.respond_to?(:manager),events:service && service.stats,
      eventSource:service && service.method(:start).source_location,
      proxySource:proxy && proxy.method(:event_service).source_location,
      connected:state && state[:connected],status:state && state[:status],busy:state && state[:busy]}
    File.write(REPORT, JSON.pretty_generate(value) + "\n")
  rescue => e
    File.write(REPORT, JSON.pretty_generate({phase:phase,error:e.message,backtrace:e.backtrace.first(8)}) + "\n")
  end
  module Receive
    def receive_frame(frame)
      super
      DSHInstalledStartupVerification.record('connected') if frame['type'] == 'ready'
      DSHInstalledStartupVerification.record('error',frame['error']) if frame['type'] == 'error'
    end
  end
end
UI.start_timer(0, false) do
  begin
    raise 'Proxy extension did not load' unless defined?(ZhiD5LocalProxy)
    ZhiD5LocalProxy.singleton_class.prepend(DSHInstalledStartupVerification::Receive)
    state = ZhiD5LocalProxy.ui_state
    DSHInstalledStartupVerification.record(state[:connected] ? 'connected' : 'extensions-loaded')
  rescue => error
    DSHInstalledStartupVerification.record('startup-error',error.message)
  end
end
