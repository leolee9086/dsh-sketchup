# frozen_string_literal: true
require 'fiddle'
require 'securerandom'

module DSHSketchupBridge
  # 网络线程仅 PostMessageW。窗口回调只预约一次 SketchUp 主线程回调，
  # 不直接在 Win32/Fiddle 调用栈里执行模型或 HtmlDialog 业务。
  # 空队列不预约任何回调；这里没有扫描队列的周期定时器。
  class MainThreadDispatcher
    WAKE_MESSAGE = 0x8000 + 0x351 unless const_defined?(:WAKE_MESSAGE)
    MAX_QUEUED = 256 unless const_defined?(:MAX_QUEUED)
    BATCH_SIZE = 32 unless const_defined?(:BATCH_SIZE)
    @live ||= {}

    class << self
      attr_reader :live
    end

    def initialize
      raise 'Create the dispatcher on SketchUp main thread' unless Thread.current == Thread.main
      raise 'Windows x64 is required for this dispatcher' unless RUBY_PLATFORM.match?(/mswin|mingw/) && Fiddle::SIZEOF_VOIDP == 8
      @owner = Thread.current
      @mutex = Mutex.new
      @queue = []
      @wake_pending = false
      @closed = false
      @posts = 0
      @callbacks = 0
      @errors = []
      @user32 = Fiddle.dlopen('user32.dll')
      @kernel32 = Fiddle.dlopen('kernel32.dll')
      ptr, int = Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT
      intptr = Fiddle::TYPE_INTPTR_T
      @post_message = function(@user32, 'PostMessageW', [ptr, int, intptr, intptr], int)
      @default_proc = function(@user32, 'DefWindowProcW', [ptr, int, intptr, intptr], intptr)
      @destroy_window = function(@user32, 'DestroyWindow', [ptr], int)
      @unregister_class = function(@user32, 'UnregisterClassW', [ptr, ptr], int)
      @instance = function(@kernel32, 'GetModuleHandleW', [ptr], ptr).call(0)
      @class_name = ("DSH.MainThread.#{SecureRandom.uuid}\0").encode('UTF-16LE')
      @window_proc = Fiddle::Closure::BlockCaller.new(intptr, [ptr, int, intptr, intptr]) do |window, message, wparam, lparam|
        if message == WAKE_MESSAGE
          begin
            schedule_drain
          rescue Exception => error
            @errors << "#{error.class}: #{error.message}"
            @errors.shift while @errors.length > 10
            warn "[DSH dispatcher] #{@errors.last}"
          end
          0
        else
          @default_proc.call(window, message, wparam, lparam)
        end
      end
      # WNDCLASSW: x64 指针对齐。只创建 message-only window，不挂接 SU 窗口过程。
      window_class = [0, 0, @window_proc.to_i, 0, 0, @instance.to_i, 0, 0, 0, 0, Fiddle::Pointer[@class_name].to_i].pack('L<L<Q<L<L<Q<Q<Q<Q<Q<Q<')
      atom = function(@user32, 'RegisterClassW', [ptr], int).call(window_class)
      raise 'RegisterClassW failed' if atom.zero?
      create = function(@user32, 'CreateWindowExW', [int, ptr, ptr, int, int, int, int, int, ptr, ptr, ptr, ptr], ptr)
      @window = create.call(0, @class_name, 0, 0, 0, 0, 0, 0, -3, 0, @instance, 0)
      if @window.to_i.zero?
        @unregister_class.call(@class_name, @instance)
        raise 'CreateWindowExW failed'
      end
      # Win32 保存的是回调地址；窗口销毁之前必须保留 Ruby closure 的强引用。
      self.class.live[@window.to_i] = self
    end

    def post(&work)
      raise ArgumentError, 'A callback is required' unless work
      wake = @mutex.synchronize do
        raise 'Dispatcher is closed' if @closed
        raise 'Dispatcher queue is full' if @queue.length >= MAX_QUEUED
        @queue << work
        next false if @wake_pending || @draining
        @wake_pending = true
      end
      wake! if wake
      true
    end

    def close
      raise 'Close the dispatcher on SketchUp main thread' unless Thread.current == @owner
      return if @closed
      @mutex.synchronize { @closed = true; @queue.clear; @wake_pending = false }
      UI.stop_timer(@drain_timer) if @drain_timer
      @drain_timer = nil
      raise 'DestroyWindow failed' if @destroy_window.call(@window).zero?
      self.class.live.delete(@window.to_i)
      @unregister_class.call(@class_name, @instance)
    end

    def stats
      @mutex.synchronize { {queued: @queue.length, posts: @posts, callbacks: @callbacks, closed: @closed, errors: @errors.dup} }
    end

    private

    def function(library, name, args, result)
      # Fiddle 默认会释放 GVL；创建/销毁窗口期间 Windows 可以同步回调 Ruby。
      Fiddle::Function.new(library[name], args, result, need_gvl: true)
    end

    def wake!
      raise 'PostMessageW failed' if @post_message.call(@window, WAKE_MESSAGE, 0, 0).zero?
      @mutex.synchronize { @posts += 1 }
    end

    def schedule_drain
      raise 'Dispatcher wake left the owning thread' unless Thread.current == @owner
      return if @closed || @drain_timer || @draining
      @drain_timer = UI.start_timer(0, false) do
        @drain_timer = nil
        drain unless @closed
      end
    end

    def drain
      raise 'Dispatcher callback left the SketchUp main thread' unless Thread.current == @owner
      batch = @mutex.synchronize do
        @callbacks += 1
        @wake_pending = false
        @draining = true
        @closed ? [] : @queue.shift(BATCH_SIZE)
      end
      batch.each do |work|
        begin
          work.call
        rescue Exception => error
          @errors << "#{error.class}: #{error.message}"
          @errors.shift while @errors.length > 10
          warn "[DSH dispatcher] #{@errors.last}"
        end
      end
      # 只在仍有实际工作时再次投递，空队列没有唤醒事件。
      wake = @mutex.synchronize do
        @draining = false
        next false if @closed || @queue.empty? || @wake_pending
        @wake_pending = true
      end
      wake! if wake
    end
  end
end
