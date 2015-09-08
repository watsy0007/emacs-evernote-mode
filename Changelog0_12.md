## Changelog for emacs-evernote-mode 0.12 ##

### **emacs-evernote-mode 0.12** (released 2010-11-18) ###

  * support auto major mode when opening, creating, renaming notes according to the name of the note
    * this uses the auto-mode-alist variable to select the major mode(magic-mode-alist is not supported)
  * support changing the major mode while the evernote mode is valid

(In Japanese)

  * ノートをオープン、作成、リネームする際に、ノートの名前に基づきmajor-modeを選択するように変更しました。
    * auto-mode-alistを参照してモードを選択します。magic-mode-alistは未サポートです。
  * evernote mode を有効にしたまま major mode を変更出来るようにしました。