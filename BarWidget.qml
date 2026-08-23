import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "kairos.flight-tracker"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // A horizontal Row is the wrong shape in a vertical bar, where each slot is
  // barSize wide and stacks downward. Rather than lay the progress bar out
  // twice, it is simply left off there -- the tooltip still carries the
  // percentage and the airport codes, and the panel is unaffected.
  readonly property bool barIsVertical: root.bar ? root.bar.vertical === true : false
  readonly property bool progressVisible: !root.barIsVertical
      && panelLoader.item !== null && panelLoader.item.showBarProgress === true
  readonly property real progressFraction: panelLoader.item ? panelLoader.item.barProgress : -1

  implicitWidth: content.implicitWidth
  implicitHeight: content.implicitHeight
  visible: true

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Row {
    id: content
    spacing: 0

    WidgetButton {
      id: button
      bar: root.bar
      text: panelLoader.item ? panelLoader.item.label : "FLT --"
      tooltipText: panelLoader.item ? panelLoader.item.tooltip : "Flight Tracker"
      hasVisualContent: true
      labelVisible: true
      // Extra breathing room beyond the default 8.5px: native text rendering
      // can paint a callsign a little wider than its measured implicitWidth,
      // and this is the buffer that keeps that drift from reaching the slot
      // next door.
      horizontalMargin: 14

      onPressed: root.togglePanel()
    }

    // The progress bar is a second WidgetButton rather than a bare Item so it
    // inherits the shell's click registration, tooltip handling, cursor, theme
    // colours and dim animation instead of reimplementing them. Its width is
    // fixed: WidgetButton normally sizes itself from its label, and a slot that
    // resized as the percentage climbed would shove its neighbours sideways
    // every refresh.
    //
    // hasVisualContent is bound rather than `visible`, because WidgetButton
    // already derives visible from it (and fades opacity with it); assigning
    // visible directly would break that binding and lose the fade.
    WidgetButton {
      id: progressButton
      bar: root.bar
      labelVisible: false
      hasVisualContent: root.progressVisible
      dimmed: panelLoader.item ? panelLoader.item.barProgressStale === true : false
      tooltipText: button.tooltipText
      fixedWidth: Style.spaceReal(52)

      onPressed: root.togglePanel()

      Item {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: Style.spaceReal(10)
        height: Style.spaceReal(6)

        // Opacity rather than Qt.darker for the unfilled track: darkening is
        // only a dimming step against a dark theme, and would push the track
        // toward the text colour on a light one.
        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: progressButton.foreground
          opacity: 0.25
        }

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * Math.max(0, Math.min(1, root.progressFraction))
          height: parent.height
          radius: height / 2
          color: progressButton.foreground

          Behavior on width {
            NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
          }
        }
      }
    }
  }
}
