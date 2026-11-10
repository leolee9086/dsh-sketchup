# frozen_string_literal: true
require_relative 'main_thread_dispatcher'

module DSHSketchupBridge
  # 本机扩展共用的主线程事件服务。它不依赖 Harness 网络连接或 Manager
  # 的启动顺序；消费者只依赖此公开接口，不访问 Manager 的实例变量。
  module EventService
    API_VERSION = 1 unless const_defined?(:API_VERSION)
    @consumers ||= {}

    class << self
      def version
        API_VERSION
      end

      def ready?
        !!@dispatcher
      end

      def start
        raise '事件服务必须在 SketchUp 主线程启动' unless Thread.current == Thread.main
        @dispatcher ||= MainThreadDispatcher.new
        unless @observer_attached
          @observer ||= ShutdownObserver.new
          Sketchup.add_observer(@observer)
          @observer_attached = true
        end
        self
      end

      def post(&work)
        raise 'SketchUp 事件服务尚未启动' unless @dispatcher
        @dispatcher.post(&work)
      end

      def attach(name, &stopped)
        start
        @consumers[name.to_s] = stopped
        self
      end

      def detach(name)
        @consumers.delete(name.to_s)
      end

      def stats
        {apiVersion: API_VERSION, ready: ready?, consumers: @consumers.keys, dispatcher: @dispatcher&.stats}
      end

      def shutdown
        callbacks, @consumers = @consumers.values, {}
        callbacks.compact.each do |callback|
          begin
            callback.call
          rescue => error
            warn "[DSH event service] consumer shutdown: #{error.class}: #{error.message}"
          end
        end
        @dispatcher.close if @dispatcher
        @dispatcher = nil
      end
    end

    class ShutdownObserver < Sketchup::AppObserver
      def onQuit
        EventService.shutdown
      end
    end
  end
end
