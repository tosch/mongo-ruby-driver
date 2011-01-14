# encoding: UTF-8

# Copyright (C) 2008-2010 10gen Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Mongo

  # A cursor with async enhancements.
  class AsyncCursor < Cursor
    include Mongo::Conversions
    include Enumerable

    def initialize(collection, opts={})
      super

      @worker_pool = @connection.worker_pool
    end

    # Get the next document specified the cursor options.
    #
    # @return [Hash, Nil] the next document or Nil if no documents remain.
    def next_document(opts={}, &blk)
      if opts[:async]
        async_exec(method(:next_document), nil, opts[:callback] || &blk)
      else
        super()
      end
    end

    # Determine whether this cursor has any remaining results.
    #
    # @return [Boolean]
    def has_next?(opts={}, &blk)
      if opts[:async]
        async_exec(method(:has_next?), nil, opts[:callback] || &blk)
      else
        super()
      end
    end

    # Get the size of the result set for this query.
    #
    # @param [Boolean] whether of not to take notice of skip and limit
    #
    # @return [Integer] the number of objects in the result set for this query.
    #
    # @raise [OperationFailure] on a database error.
    def count(skip_and_limit = false, opts={}, &blk)
      if opts[:async]
        async_exec(method(:count), [skip_and_limit], opts[:callback] || &blk)
      else
        super
      end
    end

    # Iterate over each document in this cursor, yielding it to the given
    # block.
    #
    # Iterating over an entire cursor will close it.
    #
    # @yield passes each document to a block for processing.
    #
    # @example if 'comments' represents a collection of comments:
    #   comments.find.each do |doc|
    #     puts doc['user']
    #   end
    def each(opts={}, &blk)
      if opts[:async]
        opts[:callback] ||= blk
        async_each(opts)
      else
        super()
      end
    end

    # Receive all the documents from this cursor as an array of hashes.
    #
    # Notes:
    #
    # If you've already started iterating over the cursor, the array returned
    # by this method contains only the remaining documents. See Cursor#rewind! if you
    # need to reset the cursor.
    #
    # Use of this method is discouraged - in most cases, it's much more
    # efficient to retrieve documents as you need them by iterating over the cursor.
    #
    # @return [Array] an array of documents.
    def to_a(opts={}, &blk)
      if opts[:async]
        opts[:callback] ||= blk
        async_each(opts)
      else
        super
      end
    end

    # Get the explain plan for this cursor.
    #
    # @return [Hash] a document containing the explain plan for this cursor.
    #
    # @core explain explain-instance_method
    def explain(opts={}, &blk)
      if opts[:async]
        async_exec(method(:explain), nil, opts[:callback] || &blk)
      else
        super
      end
    end

    # Close the cursor.
    #
    # Note: if a cursor is read until exhausted (read until Mongo::Constants::OP_QUERY or
    # Mongo::Constants::OP_GETMORE returns zero for the cursor id), there is no need to
    # close it manually.
    #
    # Note also: Collection#find takes an optional block argument which can be used to
    # ensure that your cursors get closed.
    #
    # @return [True]
    def close(opts={}, &blk)
      if opts[:async]
        async_exec(method(:async), nil, opts[:callback] || blk)
      else
        if @cursor_id && @cursor_id != 0
          message = BSON::ByteBuffer.new([0, 0, 0, 0])
          message.put_int(1)
          message.put_long(@cursor_id)
          @logger.debug("MONGODB cursor.close #{@cursor_id}") if @logger
          @connection.send_message(Mongo::Constants::OP_KILL_CURSORS, message, nil)
        end
        @cursor_id = 0
        @closed    = true
      end
    end

    private

    # Returns the number of documents available in the current batch without
    # causing a blocking call.
    #
    # When it returns 0, the next call to #has_next? or #next_document will
    # block as it goes to the server to fetch more documents.
    def num_in_batch
      @cache.length
    end

    # Return the number of documents remaining for this cursor.
    def num_remaining
      refresh if @cache.length == 0
      @cache.length
    end

    def refresh
      return if send_initial_query || @cursor_id.zero?
      message = BSON::ByteBuffer.new([0, 0, 0, 0])

      # DB name.
      BSON::BSON_RUBY.serialize_cstr(message, "#{@db.name}.#{@collection.name}")

      # Number of results to return.
      if @limit > 0
        limit = @limit - @returned
        if @batch_size > 0
          limit = limit < @batch_size ? limit : @batch_size
        end
        message.put_int(limit)
      else
        message.put_int(@batch_size)
      end

      # Cursor id.
      message.put_long(@cursor_id)
      @logger.debug("MONGODB cursor.refresh() for cursor #{@cursor_id}") if @logger
      results, @n_received, @cursor_id = @connection.receive_message(
          Mongo::Constants::OP_GET_MORE, message, nil, @socket, @command)
      @returned += @n_received
      @cache += results
      close_cursor_if_query_complete
    end

    ## Async helper methods

    def async_each(opts)
      callback = opts[:callback]
      num_returned = opts[:num_returned] || 0
      in_batch = num_in_batch
      count = 0

      while count < in_batch && (@limit <= 0 || num_returned < @limit)
        exception, doc = nil, nil
        begin
          doc = next_document
        rescue => e
          exception = e
        end

        callback.call exception, doc
        num_returned += 1
        count += 1
      end

      # block executed by the call to has_next?; when true, call #async_each again
      # otherwise the cursor is exhausted
      return_to_each = Proc.new do |error, more|
        unless error
          method(:async_each).call({:callback => callback, :num_returned => num_returned}) if more
        else
          # pass the exception through to the block for handling
          callback.call error, nil
        end
      end

      async_exec method(:has_next?), nil, return_to_each
    end

    def async_to_a(opts)
      rows = opts[:rows] || []
      callback = opts[:callback]
      num_returned = opts[:num_returned] || 0
      in_batch = num_in_batch
      count = 0

      # loop through all the docs in this batch since we know +in_batch+ documents are
      # available without blocking
      while count < in_batch && (@limit <= 0 || num_returned < @limit)
        exception = nil
        begin
          rows << next_document
        rescue => e
          exception = e
        end

        callback.call exception, nil if exception
        num_returned += 1
        count += 1
      end

      # block executed by the call to has_next?; when true, call #each again
      # otherwise the cursor is exhausted
      return_to_a = Proc.new do |error, more|
        unless error
          if more
            method(:async_to_a).call({:callback => callback, :rows => rows, :num_returned => num_returned})
          else
            callback.call nil, rows
          end
        else
          # pass the exception through to the block for handling
          callback.call error, nil
        end
      end

      async_exec method(:has_next?), nil, return_to_a
    end

    def async_exec(command, opts, callback)
      raise ArgumentError, "Must pass a :callback proc or a block when executing in async mode!" unless callback

      opts.delete :async if opts

      @workers.enqueue command, [opts], callback
    end
  end
end
