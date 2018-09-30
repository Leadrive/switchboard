import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:wstalk/src/message.dart';
import 'package:wstalk/src/mux_connection.dart';
import 'package:wstalk/src/raw_channel.dart';
import 'package:wstalk/src/rewindable_timer.dart';

class _LocalAnyResponseState {
  final RewindableTimer timer;
  const _LocalAnyResponseState(this.timer);
}

class _RemoteResponseState {
  // final int id;
  final Completer<Message> completer;
  final RewindableTimer timer;
  const _RemoteResponseState(/*this.id, */ this.completer, this.timer);
}

class _RemoteStreamResponseState {
  // final int id;
  final StreamController<Message> controller;
  final RewindableTimer timer;
  const _RemoteStreamResponseState(/*this.id, */ this.controller, this.timer);
}

class ChannelException implements Exception {
  final String message;
  const ChannelException(this.message);
  String toString() {
    return "ChannelException: { message: \"${message}\" }";
  }
}

abstract class Channel {
  /// We give the remote host 15 seconds to reply to a message
  static const int _receiveTimeOutMs = 15000;

  /// We give ourselves 10 seconds to reply to a message
  static const int _sendTimeOutMs = 10000;

  /// Maximum number concurrent requests
  static const int _maxConcurrentRequests = 0x7FFFFF;

  Map<int, _LocalAnyResponseState> _localAnyResponseStates =
      new Map<int, _LocalAnyResponseState>();
  Map<int, _RemoteResponseState> _remoteResponseStates =
      new Map<int, _RemoteResponseState>();
  Map<int, _RemoteStreamResponseState> _remoteStreamResponseStates =
      new Map<int, _RemoteStreamResponseState>();

  RawChannel _raw;
  Channel(RawChannel raw) {
    _raw = raw;
    _listen();
  }

  int _lastRequestId = 0;

  Future<void> get done => _raw.done;
  Future<void> close() async {
    try {
      await _raw.close();
    } catch (error) {}
    /*
    for (StreamController<Message> streamController in _streams.values) {
      streamController.close();
    }
    _streams.clear();
    */
    for (_LocalAnyResponseState state in _localAnyResponseStates.values) {
      state.timer.cancel();
    }
    _localAnyResponseStates.clear();
    for (_RemoteResponseState state in _remoteResponseStates.values) {
      state.timer.cancel();
      state.completer.completeError(new ChannelException(
          "Talk socket closing, reply cannot be received"));
    }
    _remoteResponseStates.clear();
    for (_RemoteStreamResponseState state
        in _remoteStreamResponseStates.values) {
      state.timer.cancel();
      state.controller.addError(new ChannelException(
          "Talk socket closing, replies cannot be received"));
      state.controller.close();
    }
    _remoteStreamResponseStates.clear();
  }

  /// A message was received from the remote host.
  void onMessage(Message message);

  void _onFrame(Uint8List frame) {
    try {
      // Parse general header of the message
      int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      bool hasProcedureId = (flags & 0x01) != 0;
      bool hasRequestId = (flags & 0x02) != 0;
      bool hasResponseId = (flags & 0x04) != 0;
      int o = 1;
      Uint8List procedureIdRaw = Uint8List(8);
      int requestId = 0;
      int responseId = 0;
      if (hasProcedureId) {
        procedureIdRaw = buffer.asUint8List(offset + o, 8);
        o += 8;
      }
      if (hasRequestId) {
        requestId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      if (hasResponseId) {
        responseId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      Uint8List subFrame = buffer.asUint8List(offset + o);
      String procedureId = utf8.decode(procedureIdRaw.takeWhile((c) => c != 0));
      // This message expects a stream response (if not set, can only send timeout extend stream response)
      // bool expectStreamResponse = (flags & 0x08) != 0; // not necessary?
      // This message is a stream response (a non-stream-response signals end-of-stream)
      bool isStreamResponse = (flags & 0x30) == 0x10;
      // Timeout extend message (must be a stream response) (an extend message with a request id extends the timeout)
      bool isTimeoutExtend = (flags & 0x30) == 0x30;
      // Abort message (must be non-stream response) (an abort message with a request id is a request cancellation)
      bool isAbort = (flags & 0x30) == 0x20;
      Message message = new Message(procedureId, requestId, responseId, subFrame);

      // Process message
      if (requestId != 0) {
        // This is a remote request that needs to be responded to in time
        // Ensure we're not past the concurrency limit
        int concurrentRequests = _localAnyResponseStates.length;
        if (concurrentRequests >= _maxConcurrentRequests) {
          _replyAbort(requestId, "Too many incoming concurrent requests");
          return;
        }
        // Set the timer
        RewindableTimer timer = new RewindableTimer(new Duration(milliseconds: _sendTimeOutMs), () {
          // Check if it's not already been removed, may happen due to race condition
          if (_localAnyResponseStates.containsKey(requestId)) {
            print(
                "Message was not replied to by the local program in time '$procedureId', abort");
            _replyAbort(requestId, "Reply not sent in time");
            _localAnyResponseStates.remove(requestId);
          }
        });
        _localAnyResponseStates[requestId] = new _LocalAnyResponseState(timer);
      }
      if (responseId == 0) {
        onMessage(message); // TODO -------------
      }
    } catch (error, stack) {
      // TODO: Error while handling channel frame, channel closed.
      close();
    }
  }

  void _listen() {
    _raw.listen(
      _onFrame,
      onError: (error, stack) {
        // TODO: Log error.
      },
      onDone: () {},
      cancelOnError: true,
    );
  }

  int _makeRequestId() {
    ++_lastRequestId;
    _lastRequestId &= 0xFFFFFF;
    if (_lastRequestId == 0) ++_lastRequestId;
    while ((_remoteResponseStates[_lastRequestId] ?? _remoteStreamResponseStates[_lastRequestId]) != null) {
      ++_lastRequestId;
      _lastRequestId &= 0xFFFFFF;
      if (_lastRequestId == 0) ++_lastRequestId;
    }
    return _lastRequestId;
  }

  void _sendMessage(
      String procedureId, Uint8List data, int responseId, bool isStreamResponse,
      [int requestId = 0,
      bool expectStreamResponse = false,
      bool isAbortOrExtend = false]) {
    // Check options
    bool hasProcedureId = procedureId?.isEmpty ?? false;
    bool hasRequestId = requestId != 0 && requestId != null;
    bool hasResponseId = responseId != 0 && responseId != null;
    int headerSize = 1;
    if (hasProcedureId) headerSize += 8;
    if (hasRequestId) headerSize += 3;
    if (hasResponseId) headerSize += 3;

    // Expand data frame with channel header plus mux header capacity
    int fullHeaderSize = headerSize + kMaxConnectionFrameHeaderSize;
    Uint8List fullFrame = Uint8List(fullHeaderSize) + data;
    Uint8List frame =
        fullFrame.buffer.asUint8List(kMaxConnectionFrameHeaderSize);
    int flags = 0;
    if (hasProcedureId) flags |= 0x01;
    if (hasRequestId) flags |= 0x02;
    if (hasResponseId) flags |= 0x04;
    // if (expectStreamResponse) flags |= 0x08; // not necessary?
    if (isStreamResponse) flags |= 0x10;
    if (isAbortOrExtend) flags |= 0x20;

    // Set header data
    frame[0] = flags;
    int o = 1;
    if (hasProcedureId) {
      Uint8List procedureIdRaw = utf8.encode(procedureId).take(8).toList();
      for (int i = 0; i < procedureIdRaw.length; ++i) {
        frame[o + i] = procedureIdRaw[i];
      }
      o += 8;
    }
    if (hasRequestId) {
      frame[o++] = requestId & 0xFF;
      frame[o++] = (requestId >> 8) & 0xFF;
      frame[o++] = (requestId >> 16) & 0xFF;
    }
    if (hasResponseId) {
      frame[o++] = responseId & 0xFF;
      frame[o++] = (responseId >> 8) & 0xFF;
      frame[o++] = (responseId >> 16) & 0xFF;
    }

    // Send frame
    _raw.add(frame);
  }

  void _replyAbort(int responseId, String reason) {
    _sendMessage(
        "", utf8.encode(reason), responseId, false, 0, false, true);
  }

  void _sendingResponse(int responseId, bool isStreamResponse) {
    _LocalAnyResponseState state = _localAnyResponseStates[responseId];
    if (state != null) {
      if (isStreamResponse) {
        state.timer.rewind();
      } else {
        state.timer.cancel();
        _localAnyResponseStates.remove(responseId);
      }
    } else {
      throw new ChannelException("Already sent final response (or timeout)");
    }
  }

  void sendMessage(String procedureId, Uint8List data,
      {int responseId = 0, bool isStreamResponse = false}) {
    _sendMessage(procedureId, data, responseId, isStreamResponse);
  }

  Future<Message> sendRequest(String procedureId, Uint8List data,
      {int responseId = 0, bool isStreamResponse = false}) {
    int requestId = _makeRequestId();
    _sendingResponse(responseId, isStreamResponse);
    _sendMessage(procedureId, data, responseId, isStreamResponse, requestId);
    // TODO: Handle stuff
  }

  Stream<Message> sendStreamRequest(String procedureId, Uint8List data,
      {int responseId = 0, bool isStreamResponse = false}) {
    int requestId = _makeRequestId();
    _sendingResponse(responseId, isStreamResponse);
    _sendMessage(
        procedureId, data, responseId, isStreamResponse, requestId, true);
    // TODO: Handle stuff
  }

  void replyMessage(Message replying, String procedureId, Uint8List data) {
    sendMessage(procedureId, data, responseId: replying.requestId);
  }

  Future<Message> replyRequest(
      Message replying, String procedureId, Uint8List data) {
    return sendRequest(procedureId, data, responseId: replying.requestId);
  }

  Stream<Message> replyStreamRequest(
      Message replying, String procedureId, Uint8List data) {
    return sendStreamRequest(procedureId, data, responseId: replying.requestId);
  }

  void replyMessageStream(
      Message replying, String procedureId, Uint8List data) {
    sendMessage(procedureId, data,
        responseId: replying.requestId, isStreamResponse: true);
  }

  Future<Message> replyRequestStream(
      Message replying, String procedureId, Uint8List data) {
    return sendRequest(procedureId, data,
        responseId: replying.requestId, isStreamResponse: true);
  }

  Stream<Message> replyStreamRequestStream(
      Message replying, String procedureId, Uint8List data) {
    return sendStreamRequest(procedureId, data,
        responseId: replying.requestId, isStreamResponse: true);
  }

  void replyEndOfStream(Message replying, String procedureId,
      [Uint8List data]) {
    replyMessage(replying, procedureId, data ?? new Uint8List(0));
  }

  void replyAbort(Message replying, String reason) {
    _sendingResponse(replying.requestId, false);
    _replyAbort(replying.requestId, reason);
  }

  void replyExtend(Message replying) {
    _sendingResponse(replying.requestId, true);
    _sendMessage(
        "", new Uint8List(0), replying.requestId, true, 0, false, true);
  }

  /*
  void requestAbort(Message request) {
    // Stream.cancel
  }
  */
}