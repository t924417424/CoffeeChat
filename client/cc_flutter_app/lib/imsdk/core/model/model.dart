import 'dart:convert';

import 'package:cc_flutter_app/imsdk/proto/CIM.Def.pb.dart';
import 'package:intl/intl.dart';

/// 用户信息
class UserModel {
  int userId; // 用户ID

  String nickName; // 用户昵称
  /*optional*/
  String attachInfo; // 自定义字段

  String avatarURL; // 头像URL
}