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


module EnClient
  class Command
  end

  class Reply
    attr_reader :result, :message

    def initialize(result, message)
      @result, @message = result, message
    end
  end

  class AuthCommand < Command
    attr_reader :user, :passwd

    def initialize(user, passwd)
      @user, @passwd = user, passwd
    end
  end

  class AuthReply < Reply
    def initialize
      super
    end
  end

  class UpdateCommand < Command
    attr_reader :sync_type

    def initialize(sync_type = nil)
      @sync_type = sync_type
    end
  end

  class UpdateContentsCommand < Command
  end

  class ListNoteCommand < Command
    attr_reader :notebook, :tags

    def initialize(notebook = nil, tags = nil)
      @notebook, @tags = notebook, tags
    end
  end

  class ListNoteReply < Reply
    attr_reader :notes

    def initialize(result, message, notes)
      super result, message
      @notes = notes
    end
  end

  class ListNotebookCommand < Command
  end

  class ListNotebookReply < Reply
    attr_reader :notebooks

    def initialize(notebooks, result, message)
      super result, message
      @notebooks = notebooks
    end
  end

  class ListTagCommand < Command
  end

  class ListTagReply < Reply
    attr_reader :tags

    def initialize(tags, result, message)
      super result, message
      @tags = tags
    end
  end

  class ListSearchCommand < Command
  end

  class ListSearchReply < Reply
    attr_reader :searches

    def initialize(searches, result, message)
      super result, message
      @searches = searches
    end
  end

end
