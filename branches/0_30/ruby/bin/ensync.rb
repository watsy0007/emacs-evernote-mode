#! C:/Ruby192/bin/ruby.exe -sWKu
# -*- coding: utf-8 -*-

#
#  Copyright 2011 Yusuke Kawakami
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#

require "thread"
require "socket"
require "pstore"
require "singleton"
require "fileutils"
require "logger"
require "digest/md5"

require "encommon"
require "encommand"


module EnClient
  CONTENTS_DIR   = ENMODE_SYS_DIR  + "contents/"

  APPLICATION_NAME_TEXT  = %|emacs-enclient {:version => 0.30, :editmode => "TEXT"}|
  APPLICATION_NAME_XHTML = %|emacs-enclient {:version => 0.30, :editmode => "XHTML"}|

  EVERNOTE_HOST       = "sandbox.evernote.com"
  #EVERNOTE_HOST       = "www.evernote.com"
  USER_STORE_URL      = "https://#{EVERNOTE_HOST}/edam/user"
  NOTE_STORE_URL_BASE = "http://#{EVERNOTE_HOST}/edam/note/"

  LOG = Logger.new STDOUT
  LOG.level = Logger::DEBUG


  class HTTPWithProxyClientTransport < Thrift::BaseTransport
    def initialize(url, proxy_addr = nil, proxy_port = nil)
      @url = URI url
      @headers = {'Content-Type' => 'application/x-thrift'}
      @outbuf = ""
      @proxy_addr = proxy_addr
      @proxy_port = proxy_port
    end

    def open?; true end
    def read(sz); @inbuf.read sz end
    def write(buf); @outbuf << buf end

    def add_headers(headers)
      @headers = @headers.merge(headers)
    end

    def flush
      if @proxy_addr && @proxy_port
        http = Net::HTTP::Proxy(@proxy_addr, @proxy_port).new @url.host, @url.port
      else
        http = Net::HTTP.new @url.host, @url.port
      end
      http.use_ssl = @url.scheme == "https"
      #http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      #http.verify_depth = 5
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      resp, data = http.post(@url.request_uri, @outbuf, @headers)
      @inbuf = StringIO.new data
      @outbuf = ""
    end
  end


  ContentsRequest = Struct.new :type, :guid, :usn

  class Task
    attr_accessor :command, :client_socket

    def initialize(command, client_socket)
      @command = command
      @client_socket = client_socket
    end
  end


  class AuthTask < Task
    def initialize(command, client_socket)
      super
    end

    def exec
      sm = SessionManager.instance
      reply = nil
      begin
        sm.authenticate command.user, command.passwd
        LOG.info "auth_token = '#{sm.auth_token}', shared_id = '#{sm.shared_id}'"
        reply = AuthReply.new true, nil
      rescue Evernote::EDAM::Error::EDAMUserException => ex
        reply = AuthReply.new false, ErrorUtils.get_message(ex)
      end
      Server.instance.send_reply reply, @client_socket
    end
  end


  class UpdateTask < Task
    MAX_UPDATED_ENTRY = 100

    def initialize(command, cilent_socket)
      super
    end

    def exec
      sm = SessionManager.instance
      note_store = sm.note_store
      auth_token = sm.auth_token
      sync_state = note_store.getSyncState auth_token

      LOG.info "currentTime='#{sync_state.currentTime}', fullSyncBefore='#{sync_state.fullSyncBefore}', updateCount='#{sync_state.updateCount}'"
      LOG.info "expiration=#{sm.expiration}"

      SessionManager.instance.refresh_authentication sync_state.currentTime

      dm = DBManager.instance
      last_update, usn = dm.get_sync_time_and_usn
      LOG.info "last_update='#{last_update}', USN='#{usn}'"

      return if usn == sync_state.updateCount

      if @command.sync_type == nil
        if last_update < sync_state.fullSyncBefore
          LOG.debug "full sync"
          dm.clear_db
          Server.instance.send_local_command UpdateCommand.new("full")
        else
          LOG.debug "diff sync"
          Server.instance.send_local_command UpdateCommand.new("diff")
        end
        return
      end

      sync_chunk = nil
      if @command.sync_type == "full"
        sync_chunk = note_store.getSyncChunk auth_token, usn, MAX_UPDATED_ENTRY, true
        LOG.debug "full sync (#{usn}-#{sync_chunk.chunkHighUSN})"
      elsif @command.sync_type == "diff"
        sync_chunk = note_store.getSyncChunk auth_token, usn, MAX_UPDATED_ENTRY, false
        LOG.debug "diff sync (#{usn}-#{sync_chunk.chunkHighUSN})"
      else
        LOG.error "unexpected state"
        return
      end

      sync_db sync_chunk

      if sync_chunk.chunkHighUSN == sync_chunk.updateCount
        # after getting all metadata, try to get contents of notes
        dm.set_sync_time_and_usn sync_chunk.currentTime, sync_chunk.chunkHighUSN
        Server.instance.send_local_command UpdateContentsCommand.new
      else
        dm.set_sync_time_and_usn last_update, sync_chunk.chunkHighUSN
        Server.instance.send_local_command UpdateCommand.new(sync_type)
      end

    end

    private

    def sync_db(sync_chunk)
      dm = DBManager.instance
      dm.update_notes sync_chunk.notes if sync_chunk.notes
      dm.update_notebooks sync_chunk.notebooks if sync_chunk.notebooks
      dm.update_tags sync_chunk.tags if sync_chunk.tags
      dm.update_searches sync_chunk.searches if sync_chunk.searches
      dm.expunge_notes sync_chunk.expungedNotes if sync_chunk.expungedNotes
      dm.expunge_notebooks sync_chunk.expungedNotebooks if sync_chunk.expungedNotebooks
      dm.expunge_tags sync_chunk.expungedTags if sync_chunk.expungedTags
      dm.expunge_searches sync_chunk.expungedSearches if sync_chunk.expungedSearches
    end
  end


  class UpdateContentsTask < Task
    def initialize(command, client_socket)
      super
    end

    def exec
      remain_request = DBManager.instance.handle_contents_request 1, do |request|
        file_path = CONTENTS_DIR + request.guid
        if request.type == "update"
          sm = SessionManager.instance
          content = sm.note_store.getNoteContent sm.auth_token, request.guid
          open file_path, "w" do |file|
            file.write content
          end
          LOG.info "write contents to #{file_path}"
        elsif request.type == "expunge"
          FileUtils.rm file_path if FileTest.file? file_path
          LOG.info "remove contents at #{file_path}"
        end
      end

      if remain_request > 0
        Server.instance.send_local_command UpdateContentsCommand.new
      end
    end
  end


  class ListNoteTask < Task
    def initialize(command, client_socket)
      super
    end

    def exec
      DBManager.instance.each_note do |n|
        LOG.info "guid=#{n.guid}, usn=#{n.updateSequenceNum}, created=#{n.created}, updated=#{n.updated}"
      end
      notes = DBManager.instance.all_notes
      reply = ListNoteReply.new true, nil, notes
      Server.instance.send_reply reply, @client_socket
    end
  end


  class ListNotebookTask < Task
    def initialize(command, cilent_socket)
      super
    end

    def exec
      DBManager.instance.each_notebook do |nb|
        LOG.info "guid=#{nb.guid}, usn=#{nb.updateSequenceNum}, default=#{nb.defaultNotebook}"
      end
      notebooks = DBManager.instance.all_notebooks
      reply = ListNotebookReply.new true, nil, notebooks
      Server.instance.send_reply reply, @client_socket
    end
  end


  class ListTagTask < Task
    def initialize(command, cilent_socket)
      super
    end

    def exec
      DBManager.instance.each_tag do |t|
        LOG.info "guid=#{t.guid}, usn=#{t.updateSequenceNum}, pguid=#{t.parentGuid}"
      end
      tags = DBManager.instance.all_tags
      reply = ListTagReply.new true, nil, tags
      Server.instance.send_reply reply, @client_socket
    end
  end


  class ListSearchTask < Task
    def initialize(command, cilent_socket)
      super
    end

    def exec
      DBManager.instance.each_search do |s|
        LOG.info "guid=#{s.guid}, usn=#{s.updateSequenceNum}"
      end
      searches = DBManager.instance.all_searches
      reply = ListSearchReply.new true, nil, searches
      Server.instance.send_reply @client_socket, reply
    end
  end


  class DBManager
    include Singleton

    DB_SYNC             = ENMODE_SYS_DIR  + "sync"
    DB_NOTEBOOK         = ENMODE_SYS_DIR  + "notebook"
    DB_NOTE             = ENMODE_SYS_DIR  + "note"
    DB_TAG              = ENMODE_SYS_DIR  + "tag"
    DB_SAVED_SEARCH     = ENMODE_SYS_DIR  + "saved_search"
    DB_CONTENTS_REQUEST = CONTENTS_DIR + "request"

    def initialize
      unless FileTest.directory? CONTENTS_DIR
        FileUtils.mkdir CONTENTS_DIR
      end

      @sync_db              = PStore.new DB_SYNC
      @notebook_db          = PStore.new DB_NOTEBOOK
      @note_db              = PStore.new DB_NOTE
      @tag_db               = PStore.new DB_TAG
      @search_db            = PStore.new DB_SAVED_SEARCH
      @contents_request_db  = PStore.new DB_CONTENTS_REQUEST
    end

    def clear_db
      [@sync_db, @notebook_db, @note_db, @tag_db, @search_db].each do |db|
        db.transaction do
          db.roots do |root|
            db.delete root
          end
        end
      end
    end

    def set_sync_time_and_usn(sync_time, usn)
      @sync_db.transaction do
        @sync_db['last_update'] = sync_time
        @sync_db['usn'] = usn
      end
    end

    def get_sync_time_and_usn
      @sync_db.transaction do
        last_update = @sync_db['last_update']
        usn = @sync_db['usn']
        last_update = 0 unless last_update
        usn = 0 unless usn
        [last_update, usn]
      end
    end

    def update_notebooks(notebooks)
      @notebook_db.transaction do
        notebooks.each do |nb|
          @notebook_db[nb.guid] = nb
        end
      end
    end

    def expunge_notebooks(guids)
      @notebook_db.transaction do
        guids.each do |guid|
          @notebook_db.delete guid
        end
      end
    end

    def each_notebook(&block)
      @notebook_db.transaction do
        @notebook_db.roots.each do |guid|
          yield @notebook_db[guid]
        end
      end
    end

    def all_notebooks
      result = []
      each_notebook do |n|
        result << n
      end
      result
    end

    def update_notes(notes)
      @contents_request_db.transaction do
        notes.each do |n|
          @contents_request_db[n.guid] = ContentsRequest.new "update", n.guid, n.updateSequenceNum
        end
      end
      @note_db.transaction do
        notes.each do |n|
          @note_db[n.guid] = n
        end
      end
    end

    def expunge_notes(guids)
      @contents_request_db.transaction do
        guids.each do |guid|
          @contents_request_db[guid] = ContentsRequest.new "expunge", guid, 0
        end
      end
      @note_db.transaction do
        guids.each do |guid|
          @note_db.delete guid
        end
      end
    end

    def each_note
      @note_db.transaction do
        @note_db.roots.each do |guid|
          yield @note_db[guid]
        end
      end
    end

    def all_notes
      result = []
      each_note do |n|
        result << n
      end
      result
    end

    def handle_contents_request(max_request)
      handled_request = 0
      n_request = 0
      @contents_request_db.transaction do
        n_request = @contents_request_db.roots.length
        @contents_request_db.roots.each do |guid|
          yield @contents_request_db[guid]
          handled_request += 1
          n_request -= 1
          @contents_request_db.delete guid
          break if handled_request >= max_request
        end
      end
      n_request
    end

    def update_tags(tags)
      @tag_db.transaction do
        tags.each do |t|
          @tag_db[t.guid] = t
        end
      end
    end

    def expunge_tags(guids)
      @tag_db.transaction do
        guids.each do |guid|
          @tag_db.delete guid
        end
      end
    end

    def each_tag
      @tag_db.transaction do
        @tag_db.roots.each do |guid|
          yield @tag_db[guid]
        end
      end
    end

    def all_tags
      result = []
      each_tag do |t|
        result << t
      end
      result
    end

    def update_searches(searches)
      @search_db.transaction do
        searches.each do |s|
          @search_db[s.guid] = s
        end
      end
    end

    def expunge_searches(guids)
      @search_db.transaction do
        guids.each do |guid|
          @search_db.delete guid
        end
      end
    end

    def each_search
      @search_db.transaction do
        @search_db.roots.each do |guid|
          yield @search_db[guid]
        end
      end
    end

    def all_searches
      result = []
      each_search do |s|
        result << s
      end
      result
    end
  end


  class SessionManager
    include Singleton

    DB_SESSION = ENMODE_SYS_DIR + "session"
    REFRESH_LIMIT_SEC = 300

    def initialize
      @auth_token = nil
      @shared_id  = nil
      @note_store = nil
      @user_store = nil
      @expiration = nil
    end

    def auth_token
      raise NotAuthedException.new("Not authed") unless @auth_token
      @auth_token
    end

    def shared_id
      raise NotAuthedException.new("Not authed") unless @shared_id
      @shared_id
    end

    def note_store
      raise NotAuthedException.new("Not authed") unless @note_store
      @note_store
    end

    def user_store
      raise NotAuthedException.new("Not authed") unless @user_store
      @user_store
    end

    def expiration
      raise NotAuthedException.new("Not authed") unless @expiration
      @expiration
    end

    def authenticate(user, passwd)
      appname = "kawayuu"
      appid = "24b37bd1326624a0"
      update_user_store
      auth_result = @user_store.authenticate user, passwd, appname, appid
      save_session auth_result
      update_note_store
    end

    def refresh_authentication(current_time)
      if current_time > @expiration - REFRESH_LIMIT_SEC * 1000
        update_user_store
        auth_result = @user_store.refreshAuthentication @auth_token
        save_session auth_result
        update_note_store
        LOG.debug "authentication refreshed"
      end
    end

    def update_user_store
      proxy_host, proxy_port = get_proxy

      if proxy_host
        user_store_transport = HTTPWithProxyClientTransport.new USER_STORE_URL, proxy_host, proxy_port
      else
        user_store_transport = HTTPWithProxyClientTransport.new USER_STORE_URL
      end
      user_store_protocol = Thrift::BinaryProtocol.new user_store_transport
      @user_store = Evernote::EDAM::UserStore::UserStore::Client.new user_store_protocol

      version_ok = @user_store.checkVersion("Emacs Client",
                                            Evernote::EDAM::UserStore::EDAM_VERSION_MAJOR,
                                            Evernote::EDAM::UserStore::EDAM_VERSION_MINOR)

      unless version_ok
        error "UserStore version invalid"
        @user_store = nil
      end
    end

    def update_note_store
      note_store_url = NOTE_STORE_URL_BASE + @shared_id

      proxy_host, proxy_port = get_proxy
      if proxy_host
        note_store_transport = HTTPWithProxyClientTransport.new note_store_url, proxy_host, proxy_port
      else
        note_store_transport = HTTPWithProxyClientTransport.new note_store_url
      end

      note_store_protocol = Thrift::BinaryProtocol.new note_store_transport
      @note_store = Evernote::EDAM::NoteStore::NoteStore::Client.new note_store_protocol
    end

    private

    def save_session(auth_result)
      @auth_token = auth_result.authenticationToken
      @shared_id  = auth_result.user.shardId if auth_result.user
      @expiration = auth_result.expiration
    end

    def get_proxy
      proxy_str = ENV["EN_PROXY"]
      if proxy_str
        proxy_str =~ /((?:\w|\.)+):([0-9]+)/
        [$1, $2]
      else
        nil
      end
    end
  end


  class Server
    include Singleton

    AUTO_UPDATE_INTERVAL = 20

    def initialize
      @task_queue = Queue.new
      @server_socket = nil
      @client_sockets = []
    end

    def run
      start_accept_request
      start_auto_update
      begin
        while true
          task = @task_queue.pop
          begin
            LOG.debug task.command
            task.exec
          rescue
            handle_exception $!
          end
        end
      rescue Interrupt
        LOG.debug "Interrupted"
      end
    end

    def start_accept_request
      @server_socket = TCPServer.open(0)
      sockets = [@server_socket]
      LOG.info "server is on #{@server_socket.addr.join(":")}"

      port = @server_socket.addr[1]
      ServerStat.instance.set_server_port port

      Thread.start do
        while true
          nsock = select sockets
          next if nsock == nil
          for s in nsock[0] # socket ready for input
            if s == @server_socket
              client_socket = s.accept
              sockets.push client_socket
              @client_sockets.push client_socket
              print(s, " is accepted\n")
            else # client socket
              if s.eof?
                print(s, " is gone\n")
                s.close
                sockets.delete s
                @client_sockets.delete s
              else
                command = receive_command s
                task = get_task command, s
                unless task
                  LOG.warning "unknown command"
                  next
                end
                @task_queue.push task
              end
            end
          end
        end
      end
    end

    def start_auto_update
      Thread.start do
        Utils::repeat_every AUTO_UPDATE_INTERVAL do
          send_local_command UpdateCommand.new
        end
      end
    end

    def send_local_command(command)
      task = get_task command, nil
      @task_queue.push task
    end

    def send_reply(reply, client_socket)
      Marshal.dump reply, client_socket
    end

    def broadcast(reply)
      @client_sockets.each do |s|
        Marshal.dump reply, s
      end
    end

    private

    def receive_command(client_socket)
      command = Marshal.load client_socket
    end


    TASK_MAP = {
      AuthCommand => AuthTask,
      UpdateCommand => UpdateTask,
      UpdateContentsCommand => UpdateContentsTask,
      ListNoteCommand => ListNoteTask,
      ListNotebookCommand => ListNotebookTask,
      ListTagCommand => ListTagTask,
      ListSearchCommand => ListSearchTask
    }

    def get_task(command, client_socket)
      task_class = TASK_MAP[command.class]
      return nil unless task_class
      task = task_class.new command, client_socket
    end

    def handle_exception(ex)
      error ErrorUtils.get_message(ex)
    end

    def error(msg)
      $stderr.puts msg
    end
  end

end


if __FILE__ == $0
  begin
    EnClient::Server.instance.run
  rescue
    $stderr.puts $!.backtrace
    exit 1 # unexpected error
  end
end
