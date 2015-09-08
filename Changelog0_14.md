## Changelog for emacs-evernote-mode 0.14 ##

### **emacs-evernote-mode 0.14** (released 2010-11-21) ###

  * support posting the selected region as a new note. (Command: evernote-post-region, See also [README\_English](README_English.md) for details)
  * bug fix: switch to the buffer opening an evernote note when trying to open a local file
    * In version 0.13, this bug occurs when you write a local buffer associated with a local file as a evernote note and then reopen the local file.

(In Japanese)

  * 選択されたリージョンを新規ノートとしてポストする機能をサポートしました (Command: evernote-post-region, 詳細は[README\_Japanese](README_Japanese.md) を参照して下さい)
  * bug fix: ローカルファイルを開いた際に、既にevernoteのノートを開いているバッファにカーソルが移動してしまうことがある不具合を修正しました
    * バージョン0.13では、この不具合はローカルファイルに関連付けられたバッファをevernoteのノートとして保存した後、再度そのローカルファイルを開こうとした場合に起こります