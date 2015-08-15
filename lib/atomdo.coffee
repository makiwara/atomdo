{Point, Range, Task} = require 'atom'
_ = require 'underscore'
moment = require 'moment'
CSON = require atom.config.resourcePath + "/node_modules/season/lib/cson.js"
Grammar = require atom.config.resourcePath +
  "/node_modules/first-mate/lib/grammar.js"
tasks = require './tasksUtilities'
TaskStatusView = require './views/task-status-view'
shell = require 'shell'

# Store the current settings for the markers
marker = completeMarker = cancelledMarker = archiveSeparator = attributeMarker = tagMarker = priorityMarker = ''


module.exports =

  ###
    PLUGIN CONFIGURATION:
  ###
  config:
    dateFormat:
      type: 'string', default: "YYYY-MM-DD HH:mm"
    baseMarker:
      type: 'string', default: '☐'
    completeMarker:
      type: 'string', default: '✔'
    cancelledMarker:
      type: 'string', default: '✘'
    archiveSeparator:
      type: 'string', default: '＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿'
    attributeMarker:
      type: 'string', default: '@'
    tagMarker:
      type: 'string', default: '#'
    priorityMarker:
      type: 'string', default: '!'
    attributeUrlPrefix:
      type: 'string', default: 'https://hub.corp.ebay.com/profile/'
    jiraUrlPrefix:
      type: 'string', default: 'https://jira.corp.ebay.com/browse/'
    weekRegexpCommaSeparated:
      type: 'string', default: ['sunday|воскресенье|вс', 'monday|понедельник|пн', 'tuesday|вторник|вт', 'wednesday|среда|ср', 'thursday|четверг|чт', 'friday|пятница|пт', 'saturday|суббота|сб'].join(',')



  ###*
   * Activation of the plugin. Should set up
   * all listeners and force application of grammar.
   * @param  {object} state Application state
  ###
  activate: (state) ->

    # Get the markers from settings
    marker = atom.config.get('atomdo.baseMarker')
    completeMarker = atom.config.get('atomdo.completeMarker')
    cancelledMarker = atom.config.get('atomdo.cancelledMarker')
    archiveSeparator = atom.config.get('atomdo.archiveSeparator')
    attributeMarker = atom.config.get('atomdo.attributeMarker')
    tagMarker = atom.config.get('atomdo.tagMarker')
    priorityMarker = atom.config.get('atomdo.priorityMarker')

    # Whenever a marker setting changes, update the grammar
    atom.config.observe 'atomdo.baseMarker', (val)=>
      marker = val; @updateGrammar()
    atom.config.observe 'atomdo.completeMarker', (val)=>
      completeMarker = val; @updateGrammar()
    atom.config.observe 'atomdo.cancelledMarker', (val)=>
      cancelledMarker = val; @updateGrammar()
    atom.config.observe 'atomdo.archiveSeparator', (val)=>
      archiveSeparator = val
    atom.config.observe 'atomdo.attributeMarker', (val)=>
      attributeMarker = val; @updateGrammar()
    atom.config.observe 'atomdo.tagMarker', (val)=>
      tagMarker = val; @updateGrammar()
    atom.config.observe 'atomdo.priorityMarker', (val)=>
      priorityMarker = val; @updateGrammar()

    # Update the grammar when activated
    @updateGrammar()

    # Set up the command list
    atom.commands.add 'atom-text-editor',
      "atomdo:complete": => @completeTask()
      "atomdo:cancel": => @cancelTask()
      "atomdo:archive": => @tasksArchive()
      "atomdo:update-timestamps": => @tasksUpdateTimestamp()
      "atomdo:convert-to-task": => @convertToTask()
      "atomdo:go": => @goToUrl()
      "atomdo:datetime": => @insertDatetime()
      "atomdo:reorder-up":   => @reorderTask(-1)
      "atomdo:reorder-down": => @reorderTask(+1)

    # Starts up due updates
    setInterval @updateDues, 60000

  ###*
   * Find and update dues(): convert to !due, move upfront
   * TODO move !due(day) and !due(hh:mm) upfront from archive
  ###
  updateDues: ->
      week = _.map atom.config.get('atomdo.weekRegexpCommaSeparated').split(","), (re) -> new RegExp('^'+re+'$', 'ig')
      today = new Date()
      todayWeekDay = week[today.getDay()]
      todayDate = today.toISOString().replace('T',' ')
      todayHM   = todayDate.replace(/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{3}:[0-9]{2}).*$/, '$1')

      alarmsData = {}
      atom.workspace.scan /@due\(.*?\)/ig, {}, (result, error) ->
          alarms = {}
          isAlarmed = false
          # find all lines to bring upfront
          # TODO recurring !due from Archive
          _.each result.matches, (match) ->
              alarm = (/@due\((.*?)\)/ig).exec(match.matchText)[1].match(todayWeekDay)
              if not alarm
                  m = (/@due\(([0-9]{4}.*?)\)/ig).exec(match.matchText)
                  if m
                      alarm = m[1] < todayDate
              if not alarm
                  m = (/@due\(([0-9]{2}\:[0-9]{2})\)/ig).exec(match.matchText)
                  if m
                      alarm = m[1] < todayHM
              if not alarm
                  m = (/@due\(([0-9]{1}\:[0-9]{2})\)/ig).exec(match.matchText)
                  if m
                      alarm = '0'+m[1] < todayHM
              if alarm
                  if match.range.start
                      row = match.range.start.row
                  else
                      row = match.range[0][0]
                  if not alarmsData[result.filePath]
                      alarmsData[result.filePath] = {}
                  if not alarmsData[result.filePath][row]
                      alarmsData[result.filePath][row] =
                          'row': row
                          'text': match.lineText + '\n'
                  alarmsData[result.filePath][row].text = alarmsData[result.filePath][row].text.replace(match.matchText, '!'+match.matchText.substr(1))
      # replace all @dues in given files
      _.each alarmsData, (filePath, alarms) ->
          editorPromise = atom.workspace.open filePath,
              activatePane: false
          editorPromise.then (editor) ->
              insertPoint = new Point 0, 0
              rows = []
              rows = _.sortBy alarms, 'row'
              _.each rows, (row) ->
                  editor.buffer.deleteRow row.row
                  editor.buffer.insert insertPoint, row.text
  ###*
   * Inserts time stamp under cursor
  ###
  insertDatetime: ->
      editor = atom.workspace.getActiveTextEditor()
      editor.insertText tasks.getFormattedDate()


  ###*
   * Dynamically update the grammar CSON file
   * to support user-set values for markers.
  ###
  updateGrammar: ->
    # Escape a string
    clean = (str)->
      for pat in ['\\', '/', '[', ']', '*', '.', '+', '(', ')']
        str = str.replace pat, '\\' + pat
      str

    # Replace given string's markers
    rep = (prop)->
      str = prop
      str = str.replace '☐', clean marker
      str = str.replace '✔', clean completeMarker
      str = str.replace '✘', clean cancelledMarker
      str = str.replace '@', clean attributeMarker
      str = str.replace '#', clean tagMarker
      str = str.replace '!', clean priorityMarker

    # Load in the grammar manually and do replacement
    g = CSON.readFileSync __dirname + '/atomdo.cson'
    g.repository.marker.match = rep g.repository.marker.match
    g.repository.attribute.match = rep g.repository.attribute.match
    g.repository.tag.match = rep g.repository.tag.match
    g.repository.prio.match = rep g.repository.prio.match
    g.patterns = g.patterns.map (pattern) ->
      pattern.match = rep pattern.match if pattern.match
      pattern.begin = rep pattern.begin if pattern.begin
      pattern

    # first, clear existing grammar
    atom.grammars.removeGrammarForScopeName 'source.todo'
    newG = new Grammar atom.grammars, g
    atom.grammars.addGrammar newG

    # Reset all todo grammars to match
    atom.workspace.getTextEditors().map (editorView) ->
      grammar = editorView.getGrammar()
      if grammar.name is 'AtomDo'
        editorView.setGrammar newG



  ###*
   * Helper for handling the status bar
   * @param {object} statusBar The statusbar
  ###
  consumeStatusBar: (statusBar) ->
    @taskStatus = new TaskStatusView()
    @taskStatus.initialize()
    @statusBarTile = statusBar.addLeftTile(item: @taskStatus, priority: 100)


  ###*
   * Handle deactivation of the plugin. Remove
   * all listeners and connections
  ###
  deactivate: ->
    @statusBarTile?.destroy()
    @statusBarTile = null

  ###*
   * Helper for to reordering with Alt+Up/Down
  ###
  reorderTask: (dir = 1) ->
      editor = atom.workspace.getActiveTextEditor()
      return if not editor
      selection = editor.getSelectedBufferRanges()

      editor.transact ->

          # find rows to shift
          currentTask = []
          tasks.getAllSelectionRows(selection).map (row)->
              el =
                  row: row
                  line: editor.displayBuffer.tokenizedBuffer.tokenizedLines[row]
              currentTask.push el
          # start from the first row shifting in given direction
          currentTask.sort (a,b)->
              return dir*(b.row-a.row)
          currentTask.map (el)->
              # find next/prev row
              rowToMove = el.row + dir
              lineToMove = editor.displayBuffer.tokenizedBuffer.tokenizedLines[rowToMove]
              insertRow = el.row
              deleteRow = rowToMove
              if dir < 0
                  insertRow += 1
              else
                  deleteRow += 1
              # copy row
              insertPoint = new Point insertRow, 0
              editor.buffer.insert insertPoint, lineToMove.text + '\n'
              # remove row
              editor.buffer.deleteRow deleteRow

  ###*
   * Helper for completing a task
  ###
  completeTask: ->
    editor = atom.workspace.getActiveTextEditor()
    return if not editor

    selection = editor.getSelectedBufferRanges()

    editor.transact ->
      tasks.getAllSelectionRows(selection).map (row)->
        screenLine = editor.displayBuffer.tokenizedBuffer.tokenizedLines[row]

        markerToken = tasks.getToken screenLine.tokens, tasks.markerSelector
        doneToken = tasks.getToken screenLine.tokens, tasks.doneSelector

        if markerToken and not doneToken
          # This is a task and isn't already done,
          # so calculate the projects this task
          # belongs to.
          projects = tasks.getProjects editor, row
            .map (p)-> tasks.parseProjectName p
            .reverse()

          # Clear any cancelled information beforehand
          tasks.removeTag editor, row, 'cancelled', attributeMarker
          tasks.removeTag editor, row, 'project', attributeMarker

          # Add the tag and the projects, if there are any
          tasks.addTag editor, row, attributeMarker, 'done', tasks.getFormattedDate()
          if projects.length
            tasks.addTag editor, row, attributeMarker, 'project', projects.join ' / '
          tasks.setMarker editor, row, completeMarker

        else if markerToken and doneToken
          # This task was previously completed, so
          # just need to clear out the tags
          tasks.removeTag editor, row, 'done', attributeMarker
          tasks.removeTag editor, row, 'project', attributeMarker
          tasks.setMarker editor, row, marker



  ###*
   * Helper for cancelling a task
  ###
  cancelTask: ->
    editor = atom.workspace.getActiveTextEditor()
    return if not editor

    selection = editor.getSelectedBufferRanges()

    editor.transact ->
      tasks.getAllSelectionRows(selection).map (row)->
        screenLine = editor.displayBuffer.tokenizedBuffer.tokenizedLines[row]

        markerToken = tasks.getToken screenLine.tokens, tasks.markerSelector
        cancelledToken = tasks.getToken screenLine.tokens,
          tasks.cancelledSelector

        if markerToken and not cancelledToken
          # This is a task and isn't already cancelled,
          # so calculate the projects this task
          # belongs to.
          projects = tasks.getProjects editor, row
            .map (p)-> tasks.parseProjectName p
            .reverse()

          # Clear any done information beforehand
          tasks.removeTag editor, row, 'done', attributeMarker
          tasks.removeTag editor, row, 'project', attributeMarker

          # Add the tag and the projects, if there are any
          tasks.addTag editor, row, attributeMarker, 'cancelled', tasks.getFormattedDate()
          if projects.length
            tasks.addTag editor, row, attributeMarker, 'project', projects.join ' / '
          tasks.setMarker editor, row, cancelledMarker

        else if markerToken and cancelledToken
          # This task was previously completed, so
          # just need to clear out the tags
          tasks.removeTag editor, row, 'cancelled', attributeMarker
          tasks.removeTag editor, row, 'project', attributeMarker
          tasks.setMarker editor, row, marker



  ###*
   * Helper for updating timestamps to match
   * the given settings
  ###
  tasksUpdateTimestamp: ->
    # Update timestamps to match the current setting (only for tags though)
    editor = atom.workspace.getActiveTextEditor()
    return if not editor

    selection = editor.getSelectedBufferRanges()

    editor.transact ->
      tasks.getAllSelectionRows(selection).map (row)->
        screenLine = editor.displayBuffer.tokenizedBuffer.tokenizedLines[row]
        # These tags will receive updated timestamps
        # based on existing ones
        tagsToUpdate = ['done', 'cancelled']
        for tag in tagsToUpdate
          curDate = tasks.getTag(editor, row, tag, attributeMarker)?.tagValue.value
          if curDate
            tasks.updateTag editor, row, attributeMarker, tag, tasks.getFormattedDate(curDate)


  ###*
   * Helper for opening URL in browser
  ###
  goToUrl: ->
    editor = atom.workspace.getActiveTextEditor()
    return if not editor
    selection = editor.getLastSelection();
    text = editor.getWordUnderCursor({ wordRegex: /\S*/ })
    url = false

    if text.match /^http(s?):/
        url = text.replace /[\,\.\]\)\,\!\?\;]*$/, ''
    if text.match /^@[a-z0-9]+/i
        url = text.replace /^@([a-z0-9]+).*$/i, '$1'
        url = atom.config.get('atomdo.attributeUrlPrefix') + url
    if text.match /^[A-Z]+-[0-9]+/
        url = text.replace /^([A-Z]+-[0-9]+).*$/, '$1'
        url = atom.config.get('atomdo.jiraUrlPrefix') + url

    if url
        # TODO provide Windows way to do it.
        shell.openExternal url


  ###*
   * Helper for converting a non-task
   * line to a task
  ###
  convertToTask: ->
    editor = atom.workspace.getActiveTextEditor()
    return if not editor

    selection = editor.getSelectedBufferRanges()

    editor.transact ->
      tasks.getAllSelectionRows(selection).map (row)->
        screenLine = editor.displayBuffer.tokenizedBuffer.tokenizedLines[row]
        markerToken = tasks.getToken screenLine.tokens, tasks.markerSelector
        if not markerToken or markerToken.value is marker
            tasks.setMarker editor, row, marker


  ###*
   * Helper for handling the archiving of
   * all done and cancelled tasks
  ###
  tasksArchive: ->
    editor = atom.workspace.getActiveTextEditor()
    return if not editor

    editor.transact ->

      completedTasks = []
      archiveProject = null
      prevArchive = null
      insertRow = -1

      # 1. Find the archives section, if it exists

      editor.displayBuffer.tokenizedBuffer.tokenizedLines.every (i, ind)->
        # if we already found the archive, no need
        # to parse any more!
        return false if archiveProject
        hasDone = tasks.getToken i.tokens, tasks.doneSelector
        hasCancelled = tasks.getToken i.tokens, tasks.cancelledSelector
        hasArchive = tasks.getToken i.tokens, tasks.archiveSelector
        hasMarker = tasks.getToken i.tokens, tasks.markerSelector
        hasSpaces = i.text.match /^\s/

        el =
          lineNumber: ind
          line: i

        archiveProject = el if hasArchive
        completedTasks.push el if hasDone or hasCancelled
        completedTasks.push el if prevArchive and not hasMarker and hasSpaces
        prevArchive = (hasMarker and (hasDone or hasCancelled)) or (prevArchive and not hasMarker and hasSpaces)
        true

      # 2. I have a list of all completed tasks,
      #     as well as where the archive exists, if it does

      if not archiveProject
        # no archive? create it!
        archiveText = """


        #{archiveSeparator}
        Archive:

        """

        # Before adding the final archive section,
        # we should clear out the empty lines at
        # the end of the file.
        for line, i in editor.buffer.lines by -1
          if editor.buffer.isRowBlank i
            # remove the line
            editor.buffer.deleteRow i
          else
            break

        # add to the end of the file
        newRange = editor.buffer.append archiveText
        insertRow = newRange.end.row
      else
        insertRow = archiveProject.lineNumber + 1

      # 3. Archive insertion point is ready! Let's
      #     start copying down the completed items.
      completedTasks.reverse()

      insertPoint = new Point insertRow, 0
      completedTasks.forEach (i)->
        editor.buffer.insert insertPoint, i.line.text + '\n'

      # 4. Copy is completed, start deleting the
      #     copied items
      completedTasks.forEach (i)->
        editor.buffer.deleteRow i.lineNumber
