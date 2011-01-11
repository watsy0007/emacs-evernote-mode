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

require 'optparse'
require 'cgi'
require "singleton"

require "thrift/types"
require "thrift/struct"
require "thrift/protocol/base_protocol"
require "thrift/protocol/binary_protocol"
require "thrift/transport/base_transport"
require "thrift/transport/http_client_transport"
require "Evernote/EDAM/user_store"
require "Evernote/EDAM/user_store_constants"
require "Evernote/EDAM/note_store"
require "Evernote/EDAM/limits_constants"


module EnClient
  ENMODE_SYS_DIR = File.expand_path("~/.evernote_mode") + "/"


  class NotAuthedException < StandardError; end
  class ServerNotFoundException < StandardError; end


  class ServerStat
    include Singleton

    PORT_FILE = ENMODE_SYS_DIR + "port"

    def get_server_port
      open PORT_FILE, File::RDONLY do |fp|
        port_str = fp.gets
        raise ServerNotFoundException("Server not found") unless port_str
        port_str.to_i
      end
    end

    def set_server_port(port)
      unless FileTest.directory? ENMODE_SYS_DIR
        FileUtils.mkdir ENMODE_SYS_DIR
      end

      open PORT_FILE, File::WRONLY|File::CREAT|File::TRUNC, 0600 do |fp|
        fp.puts port.to_s
      end
    end
  end


  class Utils
    def self.repeat_every(interval)
      while true
        spent_time = time_block { yield }
        sleep(interval - spent_time) if spent_time < interval
      end
    end

    def self.to_xhtml(content)
      content = CGI.escapeHTML content
      content.gsub! %r| |, %|&nbsp;|
      content.gsub! %r|\n|, %|<br clear="none"/>|
      content = NOTE_DEFAULT_HEADER + content + NOTE_DEFAULT_FOOTER
    end

    def self.unpack_utf8_string(str)
      if str =~ /"(\\\d\d\d)+"/
        utf8_str = eval str
        utf8_str.force_encoding "ASCII-8BIT" if utf8_str.respond_to? :force_encoding
        utf8_str
      else
        str
      end
    end

    def self.unpack_utf8_string_list(str_list)
      str_list.map do |elem|
        unpack_utf8_string elem
      end
    end

    private

    def self.time_block
      start_time = Time.now
      yield
      Time.now - start_time
    end
  end


  class ErrorUtils
    def self.get_message(ex)
      case ex
      when Evernote::EDAM::Error::EDAMUserException
        errorCode = ex.errorCode
        parameter = ex.parameter
        errorText = Evernote::EDAM::Error::EDAMErrorCode::VALUE_MAP[errorCode]
        "#{ex.class.name} (parameter: #{parameter} errorCode: #{errorText})"
      when Evernote::EDAM::Error::EDAMSystemException
        errorCode = ex.errorCode
        message   = ex.message
        errorText = Evernote::EDAM::Error::EDAMErrorCode::VALUE_MAP[errorCode]
        "#{ex.class.name} (message: #{message} errorCode: #{errorText})"
      when Evernote::EDAM::Error::EDAMNotFoundException
        identifier = ex.identifier
        key = ex.key
        "#{ex.class.name} (identifier: #{ex.identifier} key: #{ex.key}"
      else
        ex.message
      end
    end
  end

end
