class Dashing.SensuOverview extends Dashing.Widget

  ready: ->
    # This is fired when the widget is done being rendered

  onData: (data) ->
    console.log 'reading data'
