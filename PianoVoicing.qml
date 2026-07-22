import QtQuick 2.0
import QtQuick.Controls 1.4
import QtQuick.Dialogs 1.2
import MuseScore 3.0

MuseScore {
    id: plugin

    menuPath: "Plugins.Piano Voicing"
    description: "Automatically adjusts piano note velocity offsets"
    version: "0.7"
    pluginType: "dock"
    dockArea: "right"

    width: 340
    height: 650

    property bool processingScore: false
    property bool pluginStarted: false

    function getVoiceOffset(voiceIndex) {
        switch (voiceIndex) {
        case 0:
            return voice1Offset.value;
        case 1:
            return voice2Offset.value;
        case 2:
            return voice3Offset.value;
        case 3:
            return voice4Offset.value;
        default:
            return 0;
        }
    }

    function selectedRange(score) {
        if (!score.selection || !score.selection.isRange)
            return null;

        if (!score.selection.startSegment)
            return null;

        var endTick = -1;

        if (score.selection.endSegment)
            endTick = score.selection.endSegment.tick;

        return {
            startTick: score.selection.startSegment.tick,
            endTick: endTick,
            startStaff: score.selection.startStaff,
            endStaff: score.selection.endStaff
        };
    }

    function staffIsInsideRange(staffIndex, range) {
        if (!range)
            return true;

        return staffIndex >= range.startStaff &&
               staffIndex <= range.endStaff;
    }

    function collectNotesByTick(score, staffIndex, range) {
        var notesByTick = {};

        for (var voice = 0; voice < 4; ++voice) {
            var cursor = score.newCursor();

            cursor.staffIdx = staffIndex;
            cursor.voice = voice;

            if (range)
                cursor.rewindToTick(range.startTick);
            else
                cursor.rewind(Cursor.SCORE_START);

            while (cursor.segment) {
                if (range && range.endTick >= 0 &&
                        cursor.tick >= range.endTick) {
                    break;
                }

                var element = cursor.element;

                if (element && element.type === Element.CHORD) {
                    var tickKey = "tick_" + cursor.tick;

                    if (!notesByTick[tickKey])
                        notesByTick[tickKey] = [];

                    var chordNotes = element.notes;

                    for (var i = 0; i < chordNotes.length; ++i) {
                        notesByTick[tickKey].push({
                            note: chordNotes[i],
                            voice: voice,
                            pitch: chordNotes[i].pitch
                        });
                    }
                }

                cursor.next();
            }
        }

        return notesByTick;
    }

    function emptyResult() {
        return {
            notes: 0,
            changes: 0,
            protectedNotes: 0
        };
    }

    function arrayContains(values, value) {
        for (var i = 0; i < values.length; ++i) {
            if (values[i] === value)
                return true;
        }

        return false;
    }

    /*
     * Returns every offset this plugin could legitimately assign to a
     * note in this voice for the specified hand.
     *
     * This is used to distinguish likely plugin-managed values from
     * likely manual values.
     */
    function rightHandPluginValues(voiceIndex) {
        var voiceOffset = getVoiceOffset(voiceIndex);

        return [
            Math.min(rhHighestNoteOffset.value, voiceOffset),
            Math.min(rhOtherNotesOffset.value, voiceOffset)
        ];
    }

    function leftHandPluginValues(voiceIndex) {
        var voiceOffset = getVoiceOffset(voiceIndex);

        return [
            Math.min(lhHighestNoteOffset.value, voiceOffset),
            Math.min(lhLowestNoteOffset.value, voiceOffset),
            Math.min(lhOtherNotesOffset.value, voiceOffset)
        ];
    }

    /*
     * Normal processing:
     * - Rewrites notes whose current offset matches any value the
     *   plugin could have assigned for that hand and voice.
     * - Preserves offsets outside that set as manual.
     *
     * Forced processing:
     * - Used only after confirmation for the selected range.
     * - Replaces all offsets in that range.
     */
    function applyOffset(note, desiredOffset, allowedPluginValues, force) {
        var currentOffset = note.veloOffset;

        if (!force &&
                !arrayContains(allowedPluginValues, currentOffset)) {
            return {
                changed: false,
                protectedNote: true
            };
        }

        if (currentOffset === desiredOffset) {
            return {
                changed: false,
                protectedNote: false
            };
        }

        note.veloOffset = desiredOffset;

        return {
            changed: true,
            protectedNote: false
        };
    }

    function processRightHand(score, staffIndex, range, force) {
        var result = emptyResult();
        var notesByTick = collectNotesByTick(score, staffIndex, range);

        for (var tickKey in notesByTick) {
            if (!notesByTick.hasOwnProperty(tickKey))
                continue;

            var records = notesByTick[tickKey];

            if (records.length === 0)
                continue;

            result.notes += records.length;

            var highestPitch = records[0].pitch;

            for (var i = 1; i < records.length; ++i) {
                if (records[i].pitch > highestPitch)
                    highestPitch = records[i].pitch;
            }

            for (var j = 0; j < records.length; ++j) {
                var record = records[j];

                var positionOffset =
                        record.pitch === highestPitch
                        ? rhHighestNoteOffset.value
                        : rhOtherNotesOffset.value;

                var desiredOffset = Math.min(
                            positionOffset,
                            getVoiceOffset(record.voice)
                            );

                var outcome = applyOffset(
                            record.note,
                            desiredOffset,
                            rightHandPluginValues(record.voice),
                            force
                            );

                if (outcome.changed)
                    ++result.changes;

                if (outcome.protectedNote)
                    ++result.protectedNotes;
            }
        }

        return result;
    }

    function processLeftHand(score, staffIndex, range, force) {
        var result = emptyResult();
        var notesByTick = collectNotesByTick(score, staffIndex, range);

        for (var tickKey in notesByTick) {
            if (!notesByTick.hasOwnProperty(tickKey))
                continue;

            var records = notesByTick[tickKey];

            if (records.length === 0)
                continue;

            result.notes += records.length;

            var highestPitch = records[0].pitch;
            var lowestPitch = records[0].pitch;

            for (var i = 1; i < records.length; ++i) {
                if (records[i].pitch > highestPitch)
                    highestPitch = records[i].pitch;

                if (records[i].pitch < lowestPitch)
                    lowestPitch = records[i].pitch;
            }

            for (var j = 0; j < records.length; ++j) {
                var record = records[j];
                var positionOffset;

                if (record.pitch === lowestPitch) {
                    positionOffset = lhLowestNoteOffset.value;
                } else if (record.pitch === highestPitch) {
                    positionOffset = lhHighestNoteOffset.value;
                } else {
                    positionOffset = lhOtherNotesOffset.value;
                }

                var desiredOffset = Math.min(
                            positionOffset,
                            getVoiceOffset(record.voice)
                            );

                var outcome = applyOffset(
                            record.note,
                            desiredOffset,
                            leftHandPluginValues(record.voice),
                            force
                            );

                if (outcome.changed)
                    ++result.changes;

                if (outcome.protectedNote)
                    ++result.protectedNotes;
            }
        }

        return result;
    }

    function processScore(rangeOnly, force) {
        if (!pluginStarted)
            return;

        if (!automaticVoicing.checked && !force) {
            statusLabel.text = "Automatic voicing is off.";
            return;
        }

        if (processingScore)
            return;

        var score = curScore;

        if (!score) {
            statusLabel.text = "No score is open.";
            return;
        }

        var range = null;

        if (rangeOnly) {
            range = selectedRange(score);

            if (!range) {
                statusLabel.text =
                        "Select a rectangular range first.";
                return;
            }
        }

        var rhStaffIndex = rhStaffNumber.value - 1;
        var lhStaffIndex = lhStaffNumber.value - 1;

        if (rhEnabled.checked &&
                (rhStaffIndex < 0 || rhStaffIndex >= score.nstaves)) {
            statusLabel.text =
                    "RH staff " + rhStaffNumber.value +
                    " does not exist.";
            return;
        }

        if (lhEnabled.checked &&
                (lhStaffIndex < 0 || lhStaffIndex >= score.nstaves)) {
            statusLabel.text =
                    "LH staff " + lhStaffNumber.value +
                    " does not exist.";
            return;
        }

        if (rhEnabled.checked &&
                lhEnabled.checked &&
                rhStaffIndex === lhStaffIndex) {
            statusLabel.text =
                    "RH and LH must use different staves.";
            return;
        }

        var processRh = rhEnabled.checked &&
                staffIsInsideRange(rhStaffIndex, range);

        var processLh = lhEnabled.checked &&
                staffIsInsideRange(lhStaffIndex, range);

        if (!processRh && !processLh) {
            statusLabel.text =
                    rangeOnly
                    ? "The selected range does not include an enabled piano staff."
                    : "Both hands are disabled.";
            return;
        }

        processingScore = true;
        statusLabel.text =
                rangeOnly
                ? "Processing selected range..."
                : "Scanning piano staves...";

        var totalNotes = 0;
        var totalChanges = 0;
        var totalProtected = 0;

        score.startCmd();

        if (processRh) {
            var rhResult = processRightHand(
                        score,
                        rhStaffIndex,
                        range,
                        force
                        );

            totalNotes += rhResult.notes;
            totalChanges += rhResult.changes;
            totalProtected += rhResult.protectedNotes;
        }

        if (processLh) {
            var lhResult = processLeftHand(
                        score,
                        lhStaffIndex,
                        range,
                        force
                        );

            totalNotes += lhResult.notes;
            totalChanges += lhResult.changes;
            totalProtected += lhResult.protectedNotes;
        }

        score.endCmd();
        processingScore = false;

        if (totalNotes === 0) {
            statusLabel.text =
                    rangeOnly
                    ? "No notes found in the selected range."
                    : "No notes found on the selected staves.";
            return;
        }

        var message;

        if (totalChanges === 0) {
            message = "Scanned " + totalNotes +
                    " notes; no changes needed.";
        } else {
            message = "Updated " + totalChanges +
                    (totalChanges === 1 ? " note." : " notes.");
        }

        if (!force && totalProtected > 0) {
            message += " Preserved " + totalProtected +
                    (totalProtected === 1
                     ? " manual offset."
                     : " manual offsets.");
        }

        statusLabel.text = message;
    }

    function requestReapplySelectedRange() {
        var score = curScore;

        if (!score) {
            statusLabel.text = "No score is open.";
            return;
        }

        if (!selectedRange(score)) {
            statusLabel.text =
                    "Select a rectangular range first.";
            return;
        }

        confirmReapplyDialog.open();
    }

    Timer {
        id: updateTimer
        interval: 650
        repeat: false

        onTriggered: {
            plugin.processScore(false, false);
        }
    }

    onRun: {
        pluginStarted = true;
        statusLabel.text = "Automatic voicing is on.";
        updateTimer.restart();
    }

    onScoreStateChanged: {
        if (pluginStarted &&
                automaticVoicing.checked &&
                !processingScore) {
            updateTimer.restart();
        }
    }

    MessageDialog {
        id: confirmReapplyDialog
        title: "Reapply selected range?"
        text: "Replace velocity offsets in the selected range?"
        informativeText:
                "Only enabled piano staves inside the current rectangular range will be changed."
        icon: StandardIcon.Warning
        standardButtons: StandardButton.Yes | StandardButton.Cancel

        onYes: {
            plugin.processScore(true, true);
        }
    }

    ScrollView {
        anchors.fill: parent

        Column {
            id: controlsColumn
            width: plugin.width - 34
            spacing: 7

            Label {
                text: "Piano Voicing"
                font.bold: true
                font.pointSize: 14
            }

            CheckBox {
                id: automaticVoicing
                text: "Automatic voicing"
                checked: true

                onClicked: {
                    if (checked) {
                        statusLabel.text =
                                "Automatic voicing is on.";
                        updateTimer.restart();
                    } else {
                        updateTimer.stop();
                        statusLabel.text =
                                "Automatic voicing is off.";
                    }
                }
            }

            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text:
                    "Offsets matching possible plugin values may be " +
                    "recalculated. Other offsets are preserved as manual."
            }

            Label {
                text: "Right hand"
                font.bold: true
                font.pointSize: 11
            }

            CheckBox {
                id: rhEnabled
                text: "Process right hand"
                checked: true

                onClicked: {
                    if (pluginStarted && automaticVoicing.checked)
                        updateTimer.restart();
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "RH staff number"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: rhStaffNumber
                    minimumValue: 1
                    maximumValue: 100
                    value: 1

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Highest note"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: rhHighestNoteOffset
                    minimumValue: -127
                    maximumValue: 127
                    value: 0

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Other notes"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: rhOtherNotesOffset
                    minimumValue: -127
                    maximumValue: 127
                    value: -20

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Label {
                text: "Left hand"
                font.bold: true
                font.pointSize: 11
            }

            CheckBox {
                id: lhEnabled
                text: "Process left hand"
                checked: true

                onClicked: {
                    if (pluginStarted && automaticVoicing.checked)
                        updateTimer.restart();
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "LH staff number"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: lhStaffNumber
                    minimumValue: 1
                    maximumValue: 100
                    value: 2

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Highest note"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: lhHighestNoteOffset
                    minimumValue: -127
                    maximumValue: 127
                    value: -15

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Lowest note"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: lhLowestNoteOffset
                    minimumValue: -127
                    maximumValue: 127
                    value: 0

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Other notes"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: lhOtherNotesOffset
                    minimumValue: -127
                    maximumValue: 127
                    value: -15

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Label {
                text: "Shared voice offsets"
                font.bold: true
                font.pointSize: 11
            }

            Row {
                spacing: 10

                Label {
                    text: "Voice 1"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: voice1Offset
                    minimumValue: -127
                    maximumValue: 127
                    value: 0

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Voice 2"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: voice2Offset
                    minimumValue: -127
                    maximumValue: 127
                    value: -20

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Voice 3"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: voice3Offset
                    minimumValue: -127
                    maximumValue: 127
                    value: -20

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Row {
                spacing: 10

                Label {
                    text: "Voice 4"
                    width: 175
                    anchors.verticalCenter: parent.verticalCenter
                }

                SpinBox {
                    id: voice4Offset
                    minimumValue: -127
                    maximumValue: 127
                    value: -20

                    onValueChanged: {
                        if (pluginStarted &&
                                automaticVoicing.checked)
                            updateTimer.restart();
                    }
                }
            }

            Button {
                text: "Apply now"
                width: parent.width

                onClicked: {
                    plugin.processScore(false, false);
                }
            }

            Button {
                text: "Reapply selected range..."
                width: parent.width

                onClicked: {
                    plugin.requestReapplySelectedRange();
                }
            }

            Label {
                id: statusLabel
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Run the plugin to begin."
            }

            Item {
                width: 1
                height: 16
            }
        }
    }
}
