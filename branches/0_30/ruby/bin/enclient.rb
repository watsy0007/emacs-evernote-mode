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

require "optparse"
require "cgi"
require "logger"
require "kconv"
require "forwardable"
require "digest/md5"

require "encommon"
require "encommand"


#
# main module
#
module EnClient

  NOTE_DEFAULT_HEADER = %|<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>|

  NOTE_DEFAULT_FOOTER = %|</en-note>|

  LOG = Logger.new STDOUT
  LOG.level = Logger::INFO


  #
  # Utility for S-expr
  #
  class Formatter
    extend Forwardable

    Pair = Struct.new :key, :value

    def initialize
      @elems = []
    end

    def_delegators :@elems, :each
    def_delegators :@elems, :<<

    def to_s(indent_level=0)
      self.class.to_lisp_expr(self)
    end

    private

    def self.to_lisp_expr(obj, indent_level=0)
      str = ""
      indent = " " * indent_level

      case obj
      when String
        str << %|#{indent}"#{escape obj}"\n|
      when TrueClass
        str << "t"
      when FalseClass
        str << "nil"
      when Time
        str << %|#{indent}"#{obj}"\n|
      when Pair
        str << %|#{indent}(#{obj.key} . \n|
        str << to_lisp_expr(obj.value, indent_level + 1)
        str << %|#{indent})\n|
      when Formatter
        str << %|#{indent}(\n|
        obj.each do |elem|
          str << to_lisp_expr(elem, indent_level + 1)
        end
        str << %|#{indent})\n|
      else
        if obj == nil
          str << %|#{indent} nil\n|
        else
          str << %|#{indent} #{obj}\n|
        end
      end
    end

    def self.escape(str)
      str.gsub(/\\/,'\&\&').gsub(/"/, '\\"')
    end
  end

  #
  # Tag Information
  #
  class TagInfo
    class Node
      def initialize(tag=nil)
        @tag = tag
        @children = []
      end

      def add_child(child)
        @children << child
      end

      def get_formatter
        formatter = Formatter.new
        if @tag
          formatter << Formatter::Pair.new("guid", @tag.guid)
          formatter << Formatter::Pair.new("name", @tag.name)
          unless @children.empty?
            children = Formatter.new
            @children.each do |child|
              children << child.get_formatter
            end
            formatter << Formatter::Pair.new("children", children)
          end
        else
          unless @children.empty?
            children = Formatter.new
            @children.each do |child|
              formatter << child.get_formatter
            end
          end
        end
        formatter
      end

      def guid
        @tag.guid
      end
    end

    def initialize(tags)
      @guid_node_map = {}
      @name_node_map = {}
      @root = Node.new

      tags.each do |t|
        node = Node.new t
        @guid_node_map[t.guid] = node
        @name_node_map[t.name] = node
      end

      tags.each do |t|
        pguid = t.parentGuid
        node = @guid_node_map[t.guid]

        if pguid == nil
          @root.add_child node
        elsif @guid_node_map.key? pguid
          pnode = @guid_node_map[pguid]
          pnode.add_child node
        end
      end
    end

    def get_tag_guid(name)
      @name_node_map[name].guid if @name_node_map[name]
    end

    def get_tag_name(guid)
      @name_node_map.each do |key, value|
        if value.guid == guid
          break key
        end
      end
    end

    def print_tree
      puts @root.get_formatter.to_s
    end
  end


  class Task
    attr_accessor :message

    def initialize(message)
      @message = message
    end

    private

    def message_begin
      puts "[BEGIN]"
    end

    def message_end
      puts "[END]"
    end
  end


  class AuthReplyTask < Task
    def initialize(message)
      super
    end

    def exec
      formatter = Formatter.new
      formatter << Formatter::Pair("type", "auth")
      formatter << Formatter::Pair("result", message.result)
      formatter << Formatter::Pair("message", message.message)

      message_begin
      puts formatter.to_s
      message_end
    end
  end


  class ListNoteReplyTask < Task
    def initialize(message)
      super
    end

    def exec
      formatter = Formatter.new
      formatter << Formatter::Pair.new("type", "listnote")
      formatter << Formatter::Pair.new("result", message.result)
      formatter << Formatter::Pair.new("message", message.message)
      if message.result
        notes = Formatter.new
        message.notes.each do |note|
          note_formatter = Formatter.new
          note_formatter << Formatter::Pair.new("guid", note.guid)
          note_formatter << Formatter::Pair.new("title", note.title)
          note_formatter << Formatter::Pair.new("updated", note.updated)
          note_formatter << Formatter::Pair.new("active", note.active)
          tags_formatter = Formatter.new
          if note.tagGuids
            note.tagGuids.each do |t|
              tags_formatter << t
            end
            note_formatter << Formatter::Pair.new("tags", tags_formatter)
          end
          notes << note_formatter
        end
        formatter << Formatter::Pair.new("notes", notes)
      end

      message_begin
      puts formatter.to_s
      message_end
    end
  end


  class ListNotebookReplyTask < Task
    def initialize(message)
      super
    end

    def exec
      formatter = Formatter.new
      formatter << Formatter::Pair.new("type", "listnotebook")
      formatter << Formatter::Pair.new("result", message.result)
      formatter << Formatter::Pair.new("message", message.message)
      if message.result
        notebook_formatter = Formatter.new
        message.notebooks.each do |notebook|
          notebook_formatter << Formatter::Pair.new("guid", notebook.guid)
          notebook_formatter << Formatter::Pair.new("name", notebook.name)
          notebook_formatter << Formatter::Pair.new("defaultNotebook", note.defaultNotebook)
        end
        formatter << Formatter::Pair.new("notebooks", notebook_formatter)
      end

      message_begin
      puts formatter.to_s
      message_end
    end
  end


  class ListTagReplyTask < Task
    def initialize(message)
      super
    end

    def exec
      formatter = Formatter.new
      formatter << Formatter::Pair.new("type", "listtag")
      formatter << Formatter::Pair.new("result", message.result)
      formatter << Formatter::Pair.new("message", message.message)
      if message.result
        tag_formatter = Formatter.new
        message.tags.each do |tag|
          tag_formatter << Formatter::Pair.new("guid", tag.guid)
          tag_formatter << Formatter::Pair.new("name", tag.name)
        end
        formatter << Formatter::Pair.new("tags", tag_formatter)
      end

      message_begin
      puts formatter.to_s
      message_end
    end
  end


  class ListSearchReplyTask
    def initialize(message)
      super
    end

    def exec
      formatter = Formatter.new
      formatter << Formatter::Pair.new("type", "listsearch")
      formatter << Formatter::Pair.new("result", message.result)
      formatter << Formatter::Pair.new("message", message.message)
      if message.result
        search_formatter = Formatter.new
        message.searchs.each do |search|
          search_formatter << Formatter::Pair.new("guid", search.guid)
          search_formatter << Formatter::Pair.new("name", search.name)
          search_formatter << Formatter::Pair.new("query", search.query)
        end
        formatter << Formatter::Pair.new("searchs", search_formatter)
      end

      message_begin
      puts formatter.to_s
      message_end
    end
  end


  class CommandParser
    attr_reader :opt

    def initialize
      @opt = OptionParser.new
    end

    private

    def parse_args(args, num_mandatory)
      @opt.permute! args
      if args.length < num_mandatory
        raise OptionParser::MissingArgument.new("missing mandatory argument")
      elsif args.length > num_mandatory
        raise OptionParser::NeedlessArgument.new("redundant argument")
      end
      return Utils::unpack_utf8_string_list(args)
    end
  end


  class AuthCommandParser < CommandParser
    def parse(args)
      user, passwd = parse_args args, 2
      AuthCommand.new user, passwd
    end
  end


  class ListNoteCommandParser < CommandParser
    def parse(args)
      parse_args args, 0
      ListNoteCommand.new
    end
  end


  class ListNotebookCommandParser < CommandParser
    def parse(args)
      parse_args args, 0
      ListNotebookCommand.new
    end
  end


  class ListTagCommandParser < CommandParser
    def parse(args)
      parse_args args, 0
      ListTagCommand.new
    end
  end


  class ListSearchCommandParser < CommandParser
    def parse(args)
      parse_args args, 0
      ListSearchCommand.new
    end
  end


  class Shell
    include Singleton

    COMMAND_PARSER_MAP = {
      "auth" => AuthCommandParser.new,
      "listnote" => ListNoteCommandParser.new,
      "listnotebook" => ListNotebookCommandParser.new,
      "listtag" => ListTagCommandParser.new,
      "listsearch" => ListSearchCommandParser.new
    }

    def run
      port = ServerStat.instance.get_server_port
      LOG.info "port = #{port}"
      @client_socket = TCPSocket.open "localhost", port

      start_receive_message @client_socket

      while true
        putc("$")
        line = $stdin.gets

        args = line.split
        command_name = args.shift

        begin
          command_parser = COMMAND_PARSER_MAP[command_name]
          command = command_parser.parse args
          Marshal.dump command, @client_socket
        rescue
          LOG.error $!.backtrace
        end
      end
    end

    private

    def start_receive_message(socket)
      select_socket = [socket]

      Thread.start do
        while true
          nsock = select select_socket
          next if nsock == nil
          for s in nsock[0] # socket ready for input
            if s.eof?
              print(s, " is gone\n")
              s.close
              sockets.delete s
              return
            else
              message = receive_message s
              task = get_task message
              unless task
                LOG.warning "unknown message"
                next
              end
              task.exec
            end
          end
        end
      end
    end

    def receive_message(socket)
      message = Marshal.load socket
    end

    TASK_MAP = {
      AuthReply => AuthReplyTask,
      ListNoteReply => ListNoteReplyTask,
      ListNotebookReply => ListNotebookReplyTask,
      ListTagReply => ListTagReplyTask,
      ListSearchReply => ListSearchReplyTask
    }

    def get_task(message)
      task_class = TASK_MAP[message.class]
      return nil unless task_class
      p task_class
      task = task_class.new message
    end

  end
end # module EnClient


if __FILE__ == $0
  begin
    EnClient::Shell.instance.run
  rescue
    $stderr.puts $!.backtrace
    exit 1 # unexpected error
  end
end
