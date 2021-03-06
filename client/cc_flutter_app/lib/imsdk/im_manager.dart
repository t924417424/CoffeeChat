import 'dart:async';
import 'dart:convert';

import 'package:cc_flutter_app/imsdk/core/business/message_business.dart';
import 'package:cc_flutter_app/imsdk/core/business/session_business.dart';
import 'package:cc_flutter_app/imsdk/core/dao/session_db_provider.dart';
import 'package:cc_flutter_app/imsdk/core/business/im_client.dart';
import 'package:cc_flutter_app/imsdk/core/dao/sql_manager.dart';
import 'package:cc_flutter_app/imsdk/core/log_util.dart';
import 'package:cc_flutter_app/imsdk/core/model/model.dart';
import 'package:cc_flutter_app/imsdk/im_session.dart';
import 'package:cc_flutter_app/imsdk/proto/CIM.Def.pb.dart';
import 'package:cc_flutter_app/imsdk/proto/CIM.List.pb.dart';
import 'package:cc_flutter_app/imsdk/proto/CIM.Login.pb.dart';
import 'package:cc_flutter_app/imsdk/proto/CIM.Message.pb.dart';
import 'package:cc_flutter_app/imsdk/proto/im_header.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';

import 'core/im_user_config.dart';
import 'im_message.dart';

/// 核心类，负责IM SDK的基本操作，初始化、登录、注销、创建会话等
class IMManager extends IMessage {
  var _isInit = false;
  var _sessionDbProvider = new SessionDbProvider();
  IMUserConfig _userConfig;

  var _messageListenerCbMap = new Map<String, Function>(); // 收到一条消息的回调队列
  var sessions = new Map<String, IMSession>(); // 用户所有的会话列表

  Int64 userId;
  var nickName;
  var ip;
  var port;
  var userToken;

  /// 单实例
  static final IMManager singleton = IMManager._internal();

  factory IMManager() {
    return singleton;
  }

  IMManager._internal();

  /// 初始化
  bool init() {
    _isInit = true;
    IMClient.singleton.registerMessageService("IMManager", this);

    return true;
  }

  /// 设置当前用户的用户配置，登录前设置
  /// [userConfig] 用户配置
  void setUserConfig(IMUserConfig userConfig) {
    this._userConfig = userConfig;
  }

  /// 登录认证
  /// [userId] 用户ID
  /// [nickName] 昵称
  /// [userToken] 认证口令
  /// [ip] 服务器IP
  /// [port] 服务器端口
  /// [callback] (CIMAuthTokenRsp)
  Future login(Int64 userId, var nick, var userToken, var ip, var port) async {
    var com = new Completer();
    if (_userConfig == null) {
      com.completeError("please call setUserConfig() set user config!");
      return com.future;
    }

    this.userId = userId;
    this.nickName = nick;
    this.userToken = userToken;
    this.ip = ip;
    this.port = port;

    await SQLManager.init();

    IMClient.singleton.onDisconnect = _userConfig.onDisconnected; // 绑定回调
    IMClient.singleton.auth(userId, nick, userToken, ip, port).then((value) {
      com.complete(value);

      if (value is CIMAuthTokenRsp) {
        // 登录成功
        if (value.resultCode == CIMErrorCode.kCIM_ERR_SUCCSSE) {
          // 同步会话列表
          _syncSessionAndUnread();
        }
      }
    }).catchError((e) {
      com.completeError(e);
    });
    return com.future;
  }

  /// 注销
  void logout() {}

  /// 清理，本地数据缓存等，如聊天记录
  Future cleanup() async {
    await SQLManager.cleanup();
  }

  /// 判断是否是来自于自己的消息
  bool isSelf(int fromUserId) {
    return this.userId == fromUserId;
  }

  /// 获取所有会话
  Future<List<IMSession>> getSessionList() async {
    var completer = new Completer<List<IMSession>>();

    _sessionDbProvider.getAllSession(userId.toInt()).then((v) {
      sessions.clear();
      v.forEach((item) {
        if (item.sessionType == CIMSessionType.kCIM_SESSION_TYPE_SINGLE) {
          sessions["PEER_" + item.sessionId.toString()] = item;
        } else if (item.sessionType == CIMSessionType.kCIM_SESSION_TYPE_SINGLE) {
          sessions["GROUP_" + item.sessionId.toString()] = item;
        } else {
          LogUtil.error("IMManager", "unknow session type load to sessions map.");
        }
      });

      completer.complete(v);
    }).catchError((e) {
      completer.completeError(e);
    });

    return completer.future;
  }

  /// 获取单个会话信息
  IMSession getSession(int sessionId, CIMSessionType sessionType) {
    var key = _getSessionKey(sessionId, sessionType);
    if (sessions.containsKey(key)) {
      return sessions[key];
    }
    return null;
  }

  /// 发起一个会话
  IMSession createSession(int sessionId, CIMSessionType sessionType) {
    var msg = new IMMessage();
    msg.msgData = "";
    msg.msgType = CIMMsgType.kCIM_MSG_TYPE_UNKNOWN;
    msg.msgStatus = CIMMsgStatus.kCIM_MSG_STATUS_NONE;
    msg.sessionType = sessionType;
    msg.toSessionId = sessionId;
    msg.msgResCode = CIMResCode.kCIM_RES_CODE_OK;
    msg.clientMsgId = "";
    msg.serverMsgId = 0;
    msg.fromUserId = userId.toInt();

    IMSession session = new IMSession(
      sessionId,
      userId.toString(),
      CIMSessionType.kCIM_SESSION_TYPE_SINGLE,
      0,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      msg,
    );

    // added to map
    sessions[_getSessionKey(sessionId, sessionType)] = session;
    // add to sqlite
    _sessionDbProvider.insert(userId.toInt(), session);
    return session;
  }

  /// 发送一条消息
  /// [msgId] 客户端消息ID（uuid），请使用generateMsgId()生成
  /// [toSessionId] 单聊，则为用户ID。群聊，则为群组ID
  /// [msgType] 消息类型
  /// [sessionType] 会话类型
  /// [msgData] 消息内容
  /// @return [Future] then(CIMMsgDataAck ack).error(String err)
  Future sendMessage(
      String msgId, int toSessionId, CIMMsgType msgType, CIMSessionType sessionType, String msgData) async {
    var completer = new Completer();

    var session = getSession(toSessionId, sessionType);
    session.updatedTime = session.latestMsg.createTime;
    session.latestMsg.clientMsgId = msgId;
    session.latestMsg.fromUserId = userId.toInt();
    session.latestMsg.createTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    session.latestMsg.msgType = msgType;
    session.latestMsg.msgData = msgData;
    session.latestMsg.senderClientType = CIMClientType.kCIM_CLIENT_TYPE_DEFAULT;

    MessageBusiness.singleton.sendMessage(msgId, toSessionId, msgType, sessionType, msgData).then((v) {
      if (v is CIMMsgDataAck) {
        session.latestMsg.createTime = v.createTime;
        session.latestMsg.serverMsgId = v.serverMsgId.toInt();
        session.latestMsg.msgResCode = v.resCode;
        // 更新会话最新消息
        _sessionDbProvider.update(IMManager.singleton.userId.toInt(), toSessionId, sessionType.value, session);
        // 会话刷新
        var list = new List<IMSession>();
        list.add(session);
        _userConfig.onRefreshConversation(list);
      }
      completer.complete(v);
    }).catchError((e) {
      LogUtil.error("IMManager", "发送消息失败:" + e);
      // 更新会话最新消息
      _sessionDbProvider.update(IMManager.singleton.userId.toInt(), toSessionId, sessionType.value, session);
      // 会话刷新
      var list = new List<IMSession>();
      list.add(session);
      _userConfig.onRefreshConversation(list);
      completer.completeError(e);
    });
    return completer.future;
  }

  /// 增加收到新消息监听器
  /// [name] 唯一标志
  /// [**未实现**listener**] 原型：void onNewMessage(List<IMMessage> msgList)
  /// [listener] 原型：void onNewMessage(CIMMsgData msg)
  void addMessageListener(String name, Function listener) {
    if (!_messageListenerCbMap.containsKey(name)) {
      _messageListenerCbMap[name] = listener;
    }
  }

  /// 移除新消息监听器
  /// [name] 唯一标志
  void removeMessageListener(String name) {
    _messageListenerCbMap.remove(name);
  }

  // interface IMessage
  void onHandleMsgData(IMHeader header, CIMMsgData msg) {
    // 更新该未读消息计数和最新消息
    var key;
    if (msg.sessionType == CIMSessionType.kCIM_SESSION_TYPE_SINGLE) {
      // 单聊，注意sessionID
      key = _getSessionKey(msg.fromUserId.toInt(), msg.sessionType);
    } else {
      key = _getSessionKey(msg.toSessionId.toInt(), msg.sessionType);
    }
    if (sessions.containsKey(key)) {
      sessions[key].unreadCnt++;
      sessions[key].updatedTime = msg.createTime;
      sessions[key].latestMsg.clientMsgId = msg.msgId;
      sessions[key].latestMsg.fromUserId = msg.fromUserId.toInt();
      sessions[key].latestMsg.createTime = msg.createTime;
      sessions[key].latestMsg.msgType = msg.msgType;
      sessions[key].latestMsg.msgData = utf8.decode(msg.msgData);
      sessions[key].latestMsg.senderClientType = CIMClientType.kCIM_CLIENT_TYPE_DEFAULT;

      // 通知会话刷新
      var list = new List<IMSession>();
      list.add(sessions[key]);
      _userConfig.onRefreshConversation(list);
    }

    // 回调
    _messageListenerCbMap.forEach((k, v) {
      Function callback = v;
      callback(msg);
    });
  }

  // interface IMessage
  void onHandleMsgDataAck(IMHeader header, CIMMsgDataAck ack) {}

  // interface IMessage
  void onHandleReadNotify(IMHeader header, CIMMsgDataReadNotify readNotify) {
    IMSession session;

    var key = _getSessionKey(readNotify.sessionId.toInt(), readNotify.sessionType);
    if (sessions.containsKey(key)) {
      session = sessions[key];
    }

    if (_userConfig.onRecvReceipt != null) {
      _userConfig.onRecvReceipt(session, readNotify.msgId.toInt());
    }
  }

  // 同步会话列表和未读计数
  void _syncSessionAndUnread() async {
    LogUtil.info("_syncSessionAndUnread", "start sync session list...");
    var result = await SessionBusiness.singleton.getRecentSessionList();
    if (result is CIMRecentContactSessionRsp) {
      for (var i = 0; i < result.contactSessionList.length; i++) {
        var session = result.contactSessionList[i];
        int count =
            await _sessionDbProvider.existSession(userId.toInt(), session.sessionId.toInt(), session.sessionType.value);

        IMMessage msg = new IMMessage();
        msg.clientMsgId = session.msgId;
        msg.serverMsgId = session.serverMsgId.toInt();
        msg.createTime = session.updatedTime;
        msg.msgData = utf8.decode(session.msgData);
        msg.msgType = session.msgType;
        msg.fromUserId = session.msgFromUserId.toInt();
        msg.msgStatus = session.msgStatus;

        IMSession model = new IMSession(session.sessionId.toInt(), session.sessionId.toString(), session.sessionType,
            session.unreadCnt, session.updatedTime.toInt(), msg);

        // 存在更新
        if (count > 0) {
          _sessionDbProvider.update(userId.toInt(), session.sessionId.toInt(), session.sessionType.value, model);
        } else {
          _sessionDbProvider.insert(userId.toInt(), model);
        }
      }

      // 回调
      _userConfig.onRefresh();
      LogUtil.info("_syncSessionAndUnread", "sync session success");
    } else {
      LogUtil.error("_syncSessionAndUnread", "sync session error:$result");
    }
  }

  // 获取key
  String _getSessionKey(int toSessionId, CIMSessionType sessionType) {
    if (sessionType == CIMSessionType.kCIM_SESSION_TYPE_GROUP) {
      return "GROUP_" + toSessionId.toString();
    } else if (sessionType == CIMSessionType.kCIM_SESSION_TYPE_SINGLE) {
      return "PEER_" + toSessionId.toString();
    } else {
      LogUtil.error("IMManager onHandleReadNotify", "unknow sessionType");
      return "UNKNOWN" + toSessionId.toString();
    }
  }

  // 同步历史消息
  void _syncMessage() {}
}
