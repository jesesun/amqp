class MQ
  class Queue
    include AMQP
    
    def initialize mq, name, opts = {}
      @mq = mq
      @mq.queues[@name = name] ||= self
      @mq.callback{
        @mq.send Protocol::Queue::Declare.new({ :queue => name,
                                                :nowait => true }.merge(opts))
      }
    end
    attr_reader :name

    def bind exchange, opts = {}
      @mq.callback{
        @mq.send Protocol::Queue::Bind.new({ :queue => name,
                                             :exchange => exchange.respond_to?(:name) ? exchange.name : exchange,
                                             :routing_key => opts.delete(:key),
                                             :nowait => true }.merge(opts))
      }
      self
    end

    def unbind exchange, opts = {}
      @mq.callback{
        @mq.send Protocol::Queue::Unbind.new({ :queue => name,
                                               :exchange => exchange.respond_to?(:name) ? exchange.name : exchange,
                                               :routing_key => opts.delete(:key),
                                               :nowait => true }.merge(opts))
      }
      self
    end

    def delete opts = {}
      @mq.callback{
        @mq.send Protocol::Queue::Delete.new({ :queue => name,
                                               :nowait => true }.merge(opts))
      }
      @mq.queues.delete @name
      nil
    end
    
    #If :delay is passed as an option, the get won't be called for that number of seconds
    def pop opts = {}, &blk
      @on_msg = blk
      @ack = opts[:no_ack] === false
      popper = Proc.new do
        @mq.get_queues.push(self)
        @mq.callback{
          @mq.send Protocol::Basic::Get.new({ :queue => name,
                                              :consumer_tag => name,
                                              :no_ack => true,
                                              :nowait => true }.merge(opts))
        }
      end
      if delay = opts.delete(:delay)
        EM.add_timer(delay, popper)
      else
        popper.call
      end
      self
    end
    
    def subscribe opts = {}, &blk
      @consumer_tag = "#{name}-#{Kernel.rand(999_999_999_999)}"
      @mq.consumers[@consumer_tag] = self

      raise Error, 'already subscribed to the queue' if @on_msg

      @on_msg = blk
      @ack = opts[:no_ack] === false
      @mq.callback{
        @mq.send Protocol::Basic::Consume.new({ :queue => name,
                                                :consumer_tag => @consumer_tag,
                                                :no_ack => true,
                                                :nowait => true }.merge(opts))
      }
      self
    end

    def unsubscribe opts = {}, &blk
      @on_msg = nil
      @on_cancel = blk
      @mq.callback{
        @mq.send Protocol::Basic::Cancel.new({ :consumer_tag => @consumer_tag }.merge(opts))
      }
      self
    end

    def publish data, opts = {}
      exchange.publish(data, opts)
    end
    
    def receive headers, body
      if AMQP.closing
        #You don't need this if your using ack, and if you aren't it doesn't do much good either
        #@mq.callback{
        #  @mq.send Protocol::Basic::Reject.new({ 
        #    :delivery_tag => headers.properties[:delivery_tag],
        #    :requeue => true
        #  })
        #}
        return
      end
      if @on_msg
        @on_msg.call *(@on_msg.arity == 1 ? [body] : [headers, body])
      end
      if @ack && headers && !AMQP.closing
        @mq.callback{
          @mq.send Protocol::Basic::Ack.new({ :delivery_tag => headers.properties[:delivery_tag]})
        }
      end
    end
    
    def status opts = {}, &blk
      @on_status = blk
      @mq.callback{
        @mq.send Protocol::Queue::Declare.new({ :queue => name,
                                                :passive => true }.merge(opts))
      }
      self
    end
    
    def recieve_status declare_ok
      if @on_status
        m, c = declare_ok.message_count, declare_ok.consumer_count
        @on_status.call *(@on_status.arity == 1 ? [m] : [m, c])
        @on_status = nil
      end
    end

    def cancelled
      @on_cancel.call if @on_cancel
      @on_cancel = @on_msg = nil
      @mq.consumers.delete @consumer_tag
      @consumer_tag = nil
    end
  
    private
    
    def exchange
      @exchange ||= Exchange.new(@mq, :direct, '', :key => name)
    end
  end
end