// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';

import '../type_inference/external_ast_helper.dart';
import 'matching_cache.dart';

/// Interface for delayed creating [Expression]s.
///
/// This is used to create the expression structure pattern matching expression
/// where actual encoding and potential caching of (sub)expressions is
/// determined by the use count of each expression.
abstract class DelayedExpression {
  /// Creates the resulting [Expression].
  Expression createExpression(TypeEnvironment typeEnvironment);

  /// Returns the type of the resulting expression.
  DartType getType(TypeEnvironment typeEnvironment);

  /// Registers that this expression is used.
  ///
  /// Implementations must call recursively into subexpression, such that both
  /// direct and indirect use is counted.
  void registerUse();

  /// Returns `true` if this expression or subexpressions uses [expression].
  ///
  /// This is used to determine whether [expression] needs to be included purely
  /// for effect or whether the effect trigger by the use through a
  /// subexpression. For instance:
  ///
  ///     if (o case Foo(bar: _, baz: 5)) { ... }
  ///
  /// Here the value of accessing `Foo.bar` on `o` is not uses in the subpattern
  /// `_` and the matched must therefore be encoded as `let # = o.bar in true`
  /// to trigger the access and its potential side effects. Since the value of
  /// accessing `Foo.baz` _is_ used by the subpattern, this match can simply be
  /// encoded as `o.baz == 5` instead of the redundant
  /// `let # o.baz in o.baz == 5`.
  bool uses(DelayedExpression expression);
}

/// A [DelayedExpression] based on an explicit [Expression] value.
///
/// This expression can only be used once.
class FixedExpression implements DelayedExpression {
  final Expression _expression;
  final DartType _type;

  bool used = false;

  FixedExpression(this._expression, this._type);

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return _expression;
  }

  @override
  void registerUse() {
    assert(!used, "FixedExpression can only be used once.");
    used = true;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) => _type;

  @override
  bool uses(DelayedExpression expression) => identical(this, expression);
}

/// A bool literal expression of the boolean [value].
class BooleanExpression implements DelayedExpression {
  final bool value;
  final int fileOffset;

  BooleanExpression(this.value, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createBoolLiteral(value, fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) =>
      typeEnvironment.coreTypes.boolNonNullableRawType;

  @override
  void registerUse() {}

  @override
  bool uses(DelayedExpression expression) => identical(this, expression);
}

/// An int literal expression of the integer [value].
class IntegerExpression implements DelayedExpression {
  final int value;
  final int fileOffset;

  IntegerExpression(this.value, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createIntLiteral(value, fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) =>
      typeEnvironment.coreTypes.intNonNullableRawType;

  @override
  void registerUse() {}

  @override
  bool uses(DelayedExpression expression) => identical(this, expression);
}

/// A lazy-and expression of the [_left] and [_right] expressions.
class DelayedAndExpression implements DelayedExpression {
  final DelayedExpression _left;
  final DelayedExpression _right;
  final int fileOffset;

  DelayedAndExpression(this._left, this._right, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createAndExpression(_left.createExpression(typeEnvironment),
        _right.createExpression(typeEnvironment),
        fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) =>
      typeEnvironment.coreTypes.boolNonNullableRawType;

  @override
  void registerUse() {
    _left.registerUse();
    _right.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) ||
      _left.uses(expression) ||
      _right.uses(expression);

  static DelayedExpression merge(
      DelayedExpression? left, DelayedExpression right,
      {required int fileOffset}) {
    if (left != null) {
      return new DelayedAndExpression(left, right, fileOffset: fileOffset);
    } else {
      return right;
    }
  }
}

/// A lazy-or expression of the [_left] and [_right] expressions.
class DelayedOrExpression implements DelayedExpression {
  final DelayedExpression _left;
  final DelayedExpression _right;
  final int fileOffset;

  DelayedOrExpression(this._left, this._right, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createOrExpression(_left.createExpression(typeEnvironment),
        _right.createExpression(typeEnvironment),
        fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) =>
      typeEnvironment.coreTypes.boolNonNullableRawType;

  @override
  void registerUse() {
    _left.registerUse();
    _right.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) ||
      _left.uses(expression) ||
      _right.uses(expression);
}

/// A conditional expression of the [_condition], [_then] and [_otherwise]
/// expressions.
class DelayedConditionExpression implements DelayedExpression {
  final DelayedExpression _condition;
  final DelayedExpression _then;
  final DelayedExpression _otherwise;
  final int fileOffset;

  DelayedConditionExpression(this._condition, this._then, this._otherwise,
      {required this.fileOffset});

  @override
  DartType getType(TypeEnvironment typeEnvironment) =>
      typeEnvironment.coreTypes.boolNonNullableRawType;

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createConditionalExpression(
        _condition.createExpression(typeEnvironment),
        _then.createExpression(typeEnvironment),
        _otherwise.createExpression(typeEnvironment),
        staticType: typeEnvironment.coreTypes.boolNonNullableRawType,
        fileOffset: fileOffset);
  }

  @override
  void registerUse() {
    _condition.registerUse();
    _then.registerUse();
    _otherwise.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) ||
      _condition.uses(expression) ||
      _then.uses(expression) ||
      _otherwise.uses(expression);
}

/// An assignment of [_variable] with [_value].
///
/// If [allowFinalAssignment] is `true`, the created [VariableSet] is allowed to
/// assign to a final variable. This is used for encoding initialization of
/// final pattern variables.
// TODO(johnniwinther): Should we instead mark the variable as non-final?
class VariableSetExpression implements DelayedExpression {
  final VariableDeclaration _variable;
  final CacheableExpression _value;
  final bool allowFinalAssignment;
  final int fileOffset;

  VariableSetExpression(this._variable, this._value,
      {this.allowFinalAssignment = false, required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createVariableSet(
        _variable, _value.createExpression(typeEnvironment),
        allowFinalAssignment: allowFinalAssignment, fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _value.getType(typeEnvironment);
  }

  @override
  void registerUse() {
    _value.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _value.uses(expression);
}

/// A expression that executes [_effect] for effect and results in [_result].
///
/// This is encoded as `let # = effect in result`.
class EffectExpression implements DelayedExpression {
  final DelayedExpression _effect;
  final DelayedExpression _result;

  EffectExpression(this._effect, this._result);

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createLetEffect(
        effect: _effect.createExpression(typeEnvironment),
        result: _result.createExpression(typeEnvironment));
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _result.getType(typeEnvironment);
  }

  @override
  void registerUse() {
    _effect.registerUse();
    _result.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) ||
      _effect.uses(expression) ||
      _result.uses(expression);
}

/// An is-test of [_operand] against [_type].
class DelayedIsExpression implements DelayedExpression {
  final DelayedExpression _operand;
  final DartType _type;
  final int fileOffset;

  DelayedIsExpression(this._operand, this._type, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createIsExpression(_operand.createExpression(typeEnvironment), _type,
        forNonNullableByDefault: true, fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return typeEnvironment.coreTypes.boolNonNullableRawType;
  }

  @override
  void registerUse() {
    _operand.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _operand.uses(expression);
}

/// An as-cast of [_operand] against [_type].
class DelayedAsExpression implements DelayedExpression {
  final DelayedExpression _operand;
  final DartType _type;
  final bool isUnchecked;
  final int fileOffset;

  DelayedAsExpression(this._operand, this._type,
      {this.isUnchecked = false, required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createAsExpression(_operand.createExpression(typeEnvironment), _type,
        forNonNullableByDefault: true,
        isUnchecked: isUnchecked,
        fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _type;
  }

  @override
  void registerUse() {
    _operand.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _operand.uses(expression);
}

/// An null-assert, e!, of [_operand].
class DelayedNullAssertExpression implements DelayedExpression {
  final DelayedExpression _operand;
  final int fileOffset;

  DelayedNullAssertExpression(this._operand, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createNullCheck(_operand.createExpression(typeEnvironment),
        fileOffset: fileOffset);
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _operand.getType(typeEnvironment).toNonNull();
  }

  @override
  void registerUse() {
    _operand.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _operand.uses(expression);
}

/// An null check,e != null, of [_operand].
class DelayedNullCheckExpression implements DelayedExpression {
  final DelayedExpression _operand;
  final int fileOffset;

  DelayedNullCheckExpression(this._operand, {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createNot(createEqualsNull(
        _operand.createExpression(typeEnvironment),
        fileOffset: fileOffset));
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return typeEnvironment.coreTypes.boolNonNullableRawType;
  }

  @override
  void registerUse() {
    _operand.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _operand.uses(expression);
}

/// An access to [_target] on [_receiver].
///
/// The [_resultType] is the static type of expression. If [isObjectAccess] is
/// `true`, the [_target] is an Object member accessed on a non-Object type,
/// for instance a nullable access to `hashCode`.
class DelayedInstanceGet implements DelayedExpression {
  final CacheableExpression _receiver;
  final Member _target;
  final DartType _resultType;
  final bool isObjectAccess;
  final int fileOffset;

  DelayedInstanceGet(this._receiver, this._target, this._resultType,
      {required this.fileOffset, this.isObjectAccess = false});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    Member target = _target;
    if (target is Procedure && !target.isGetter) {
      return new InstanceTearOff(
          isObjectAccess
              ? InstanceAccessKind.Object
              : InstanceAccessKind.Instance,
          _receiver.createExpression(typeEnvironment),
          _target.name,
          interfaceTarget: target,
          resultType: _resultType)
        ..fileOffset = fileOffset;
    } else {
      return new InstanceGet(
          isObjectAccess
              ? InstanceAccessKind.Object
              : InstanceAccessKind.Instance,
          _receiver.createExpression(typeEnvironment),
          _target.name,
          interfaceTarget: target,
          resultType: _resultType)
        ..fileOffset = fileOffset;
    }
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _resultType;
  }

  @override
  void registerUse() {
    _receiver.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _receiver.uses(expression);
}

/// An access to [_propertyName] on [_receiver] with no statically known target.
///
/// The [_resultType] is the static type of expression.
class DelayedDynamicGet implements DelayedExpression {
  final CacheableExpression _receiver;
  final Name _propertyName;
  final DynamicAccessKind _kind;
  final DartType _resultType;
  final int fileOffset;

  DelayedDynamicGet(
      this._receiver, this._propertyName, this._kind, this._resultType,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new DynamicGet(
        _kind, _receiver.createExpression(typeEnvironment), _propertyName)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _resultType;
  }

  @override
  void registerUse() {
    _receiver.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _receiver.uses(expression);
}

/// An access to `call` on the function typed [_receiver].
///
/// The [_resultType] is the static type of expression.
class DelayedFunctionTearOff implements DelayedExpression {
  final CacheableExpression _receiver;
  final DartType _resultType;
  final int fileOffset;

  DelayedFunctionTearOff(this._receiver, this._resultType,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new FunctionTearOff(_receiver.createExpression(typeEnvironment))
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _resultType;
  }

  @override
  void registerUse() {
    _receiver.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _receiver.uses(expression);
}

/// An invocation of [_methodName] on [_receiver] with the provided positional
/// [_arguments] and no statically known target.
///
/// The [_resultType] is the static type of expression.
class DelayedDynamicInvocation implements DelayedExpression {
  final CacheableExpression _receiver;
  final Name _methodName;
  final List<DelayedExpression> _arguments;
  final DynamicAccessKind _kind;
  final DartType _resultType;
  final int fileOffset;

  DelayedDynamicInvocation(this._receiver, this._methodName, this._arguments,
      this._kind, this._resultType,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new DynamicInvocation(
        _kind,
        _receiver.createExpression(typeEnvironment),
        _methodName,
        new Arguments(
            _arguments.map((e) => e.createExpression(typeEnvironment)).toList())
          ..fileOffset = fileOffset)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _resultType;
  }

  @override
  void registerUse() {
    _receiver.registerUse();
    for (DelayedExpression argument in _arguments) {
      argument.registerUse();
    }
  }

  @override
  bool uses(DelayedExpression expression) {
    if (identical(this, expression)) return true;
    if (_receiver.uses(expression)) return true;
    for (DelayedExpression argument in _arguments) {
      if (argument.uses(expression)) {
        return true;
      }
    }
    return false;
  }
}

/// An indexed record field access on [_receiver] of type [_recordType].
///
/// The [_resultType] is the static type of expression.
class DelayedRecordIndexGet implements DelayedExpression {
  final CacheableExpression _receiver;
  final RecordType _recordType;
  final int _index;
  final int fileOffset;

  DelayedRecordIndexGet(this._receiver, this._recordType, this._index,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new RecordIndexGet(
        _receiver.createExpression(typeEnvironment), _recordType, _index)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _recordType.positional[_index];
  }

  @override
  void registerUse() {
    _receiver.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _receiver.uses(expression);
}

/// An access of record field [_name] on [_receiver] of type [_recordType].
///
/// The [_resultType] is the static type of expression.
class DelayedRecordNameGet implements DelayedExpression {
  final CacheableExpression _receiver;
  final RecordType _recordType;
  final String _name;
  final int fileOffset;

  DelayedRecordNameGet(this._receiver, this._recordType, this._name,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new RecordNameGet(
        _receiver.createExpression(typeEnvironment), _recordType, _name)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _recordType.named
        .singleWhere((element) => element.name == _name)
        .type;
  }

  @override
  void registerUse() {
    _receiver.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) || _receiver.uses(expression);
}

/// An invocation of [_target] on [receiver] with the positional [_arguments].
///
/// The [_functionType] is the static type of the invocation.
class DelayedInstanceInvocation implements DelayedExpression {
  final CacheableExpression _receiver;
  final Procedure _target;
  final FunctionType _functionType;
  final List<DelayedExpression> _arguments;
  final int fileOffset;

  DelayedInstanceInvocation(
      this._receiver, this._target, this._functionType, this._arguments,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new InstanceInvocation(
        InstanceAccessKind.Instance,
        _receiver.createExpression(typeEnvironment),
        _target.name,
        new Arguments(
            _arguments.map((e) => e.createExpression(typeEnvironment)).toList())
          ..fileOffset = fileOffset,
        interfaceTarget: _target,
        functionType: _functionType)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _functionType.returnType;
  }

  @override
  void registerUse() {
    _receiver.registerUse();
    for (DelayedExpression argument in _arguments) {
      argument.registerUse();
    }
  }

  @override
  bool uses(DelayedExpression expression) {
    if (identical(this, expression)) return true;
    if (_receiver.uses(expression)) return true;
    for (DelayedExpression argument in _arguments) {
      if (argument.uses(expression)) {
        return true;
      }
    }
    return false;
  }
}

/// A static invocation of the lowered extension or inline class [_target] with
/// the provided [_arguments] and [_typeArguments].
///
/// The [_functionType] is the static type of the invocation.
class DelayedExtensionInvocation implements DelayedExpression {
  final Procedure _target;
  final List<DelayedExpression> _arguments;
  final List<DartType> _typeArguments;
  final FunctionType _functionType;
  final int fileOffset;

  DelayedExtensionInvocation(
      this._target, this._arguments, this._typeArguments, this._functionType,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new StaticInvocation(
        _target,
        new Arguments(
            _arguments.map((e) => e.createExpression(typeEnvironment)).toList(),
            types: _typeArguments)
          ..fileOffset = fileOffset)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _functionType.returnType;
  }

  @override
  void registerUse() {
    for (DelayedExpression argument in _arguments) {
      argument.registerUse();
    }
  }

  @override
  bool uses(DelayedExpression expression) {
    if (identical(this, expression)) return true;
    for (DelayedExpression argument in _arguments) {
      if (argument.uses(expression)) {
        return true;
      }
    }
    return false;
  }
}

/// An invocation of the `==` operator [_target] of type [_functionType] on
/// [_left]  with [_right].
class DelayedEqualsExpression implements DelayedExpression {
  final CacheableExpression _left;
  final DelayedExpression _right;
  final Procedure _target;
  final FunctionType _functionType;
  final int fileOffset;

  DelayedEqualsExpression(
      this._left, this._right, this._target, this._functionType,
      {required this.fileOffset});

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return new EqualsCall(_left.createExpression(typeEnvironment),
        _right.createExpression(typeEnvironment),
        functionType: _functionType, interfaceTarget: _target)
      ..fileOffset = fileOffset;
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return _functionType.returnType;
  }

  @override
  void registerUse() {
    _left.registerUse();
    _right.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) =>
      identical(this, expression) ||
      _left.uses(expression) ||
      _right.uses(expression);
}

/// A negation of [_expression].
class DelayedNotExpression implements DelayedExpression {
  final DelayedExpression _expression;

  DelayedNotExpression(this._expression);

  @override
  Expression createExpression(TypeEnvironment typeEnvironment) {
    return createNot(_expression.createExpression(typeEnvironment));
  }

  @override
  DartType getType(TypeEnvironment typeEnvironment) {
    return typeEnvironment.coreTypes.boolNonNullableRawType;
  }

  @override
  void registerUse() {
    _expression.registerUse();
  }

  @override
  bool uses(DelayedExpression expression) {
    return identical(this, expression) || _expression.uses(expression);
  }
}
