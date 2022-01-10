import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:analyzer/dart/element/type_visitor.dart';
import 'package:build/build.dart';
import 'package:collection/collection.dart';

import '../preparation/ast.dart' as zap;
import '../errors.dart';
import '../utils/dart.dart';
import 'component.dart';
import 'dart.dart';
import 'external_component.dart';
import 'flow.dart';
import 'preparation.dart';
import 'reactive_dom.dart';
import 'types/checker.dart';
import 'types/dom_types.dart';

const _reactiveUpdatesLabel = r'$';

class Resolver {
  final PrepareResult prepare;
  final LibraryElement preparedLibrary;
  final CompilationUnit preparedUnit;
  final ErrorReporter errorReporter;
  final String componentName;

  final _ScopeInformation scope;
  final List<ExternalComponent> components = [];
  late final TypeChecker checker;
  late final _AnalyzeVariablesAndScopes dartAnalysis;

  TypeProvider get typeProvider => preparedLibrary.typeProvider;
  TypeSystem get typeSystem => preparedLibrary.typeSystem;

  Resolver(
    this.prepare,
    this.preparedLibrary,
    this.preparedUnit,
    this.errorReporter,
    this.componentName,
  ) : scope = _ScopeInformation(prepare.rootScope);

  Future<ResolvedComponent> resolve(BuildStep buildStep) async {
    checker = await TypeChecker.checkerFor(
        typeProvider, typeSystem, errorReporter, buildStep);
    _findExternalComponents();
    dartAnalysis = _AnalyzeVariablesAndScopes(this);

    // Create resolved scopes and variables
    preparedUnit.accept(dartAnalysis);

    final translator = _DomTranslator(this);
    prepare.component.accept(translator, null);
    final rootFragment = DomFragment(
        translator._finishChildGroup().children, scope.resolvedRootScope);

    final component =
        _FindComponents(this, rootFragment, prepare.slots).inferComponent();

    // Mark all variables read in a flow
    for (final flow in component.flows) {
      for (final variable in flow.dependencies) {
        variable.isInReactiveRead = true;
      }
    }

    _assignUpdateFlags(scope.scopes[scope.root]!);
    return ResolvedComponent(componentName, component, prepare.cssClassName);
  }

  void _findExternalComponents() {
    preparedLibrary.importedLibraries
        .map((l) => l.exportNamespace)
        .fold<Map<String, Element>>(
            <String, Element>{},
            (names, ns) =>
                names..addAll(ns.definedNames)).forEach((name, element) {
      if (element is ClassElement && isComponent(element)) {
        components.add(_readComponent(name, element));
      }
    });
  }

  ExternalComponent _readComponent(String name, ClassElement element) {
    final parameters = <MapEntry<String, DartType>>[];
    var slots = <String?>[];

    for (final accessor in element.fields) {
      final getter = accessor.getter;
      final annotations =
          getter == null ? null : readSlotAnnotations(getter).toList();

      if (annotations != null && annotations.isNotEmpty) {
        // This is the getter introduced to represent slots
        slots = annotations;
      } else {
        parameters.add(MapEntry(accessor.name, accessor.type));
      }
    }

    // Note: We're not using element.name since the name may be aliased.
    return ExternalComponent(name, parameters, slots);
  }

  void _assignUpdateFlags(ZapVariableScope scope, [int start = 0]) {
    for (final variable in scope.declaredVariables) {
      if (variable.needsUpdateTracking) {
        variable.updateSlot = start++;
      }
    }

    // Child scopes can re-use higher update numbers since variables in
    // different child scopes aren't visible to each other.
    for (final scope in scope.childScopes) {
      _assignUpdateFlags(scope, start);
    }
  }
}

class _ScopeInformation {
  final PreparedVariableScope root;

  final Map<PreparedVariableScope, ZapVariableScope> scopes = {};
  final Map<LocalElement, BaseZapVariable> variables = {};

  final Map<zap.RawDartExpression, ScopedDartExpression> expressionToScope = {};
  final Map<zap.RawDartExpression, Expression> resolvedExpressions = {};

  ZapVariableScope get resolvedRootScope => scopes[root]!;

  _ScopeInformation(this.root) {
    void addExpressionsFrom(PreparedVariableScope scope) {
      for (final expr in scope.dartExpressions) {
        expressionToScope[expr.expression] = expr;
      }

      scope.children.forEach(addExpressionsFrom);
    }

    addExpressionsFrom(root);
  }

  void addVariable(BaseZapVariable variable) {
    variable.scope.declaredVariables.add(variable);
    variables[variable.element] = variable;
  }
}

class _AnalyzeVariablesAndScopes extends RecursiveAstVisitor<void> {
  var _isInReactiveRead = false;
  var _hasSeenRootFunction = false;

  PreparedVariableScope scope;

  final Resolver resolver;

  final _ScopeInformation scopes;
  final List<ExecutableElement> definedFunctions = [];

  _AnalyzeVariablesAndScopes(this.resolver)
      : scopes = resolver.scope,
        scope = resolver.scope.root;

  ZapVariableScope get zapScope => scopes.scopes[scope]!;

  BaseZapVariable? _variableFor(Element element) {
    return scopes.variables[element];
  }

  void _markMutable(Element? target) {
    if (target != null) {
      _variableFor(target)?.isMutable = true;
    }
  }

  Expression _resolveExpression(zap.RawDartExpression expr) {
    return scopes.resolvedExpressions.putIfAbsent(expr, () {
      final scoped = scopes.expressionToScope[expr]!;
      final scope = scopes.scopes[scoped.scope]!;

      ZapVariableScope scopeForFunction = scope;
      // Some scopes don't have a helper function in the intermediate Dart file,
      // just use the one from the parent then.
      while (scopeForFunction.function == null) {
        scopeForFunction = scope.parent!;
      }

      final body = scopeForFunction.function!.functionExpression.body
          as BlockFunctionBody;
      final name = scoped.localVariableName;

      final declaration = body.block.statements
          .whereType<VariableDeclarationStatement>()
          .firstWhere((element) {
        return element.variables.variables.any((v) => v.name.name == name);
      });

      return declaration.variables.variables.single.initializer!;
    });
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final element = node.declaredElement;

    if (!_hasSeenRootFunction) {
      scopes.scopes[scope] = ZapVariableScope(node);

      // We're analyzing the function for the root scope. Read the element for
      // the "ComponentOrPending" parameter added to the helper code.
      final selfDecl = node.functionExpression.parameters?.parameters.single;
      final selfElement =
          node.functionExpression.parameters?.parameterElements.single;

      scopes.addVariable(SelfReference(zapScope, selfDecl!, selfElement!));
      _hasSeenRootFunction = true;

      super.visitFunctionDeclaration(node);
    } else if (element != null && element.name.startsWith(zapPrefix)) {
      final currentScope = scope;
      final currentResolvedScope = zapScope;

      // This function introduces a new scope for a nested block.
      final child =
          scope.children.singleWhere((e) => e.blockName == node.name.name);

      scope = child;
      final substitution = Map.of(currentResolvedScope.instantiation);
      final resolvedScope = scopes.scopes[scope] =
          ZapVariableScope(node, instantiation: substitution);
      resolvedScope.parent = currentResolvedScope;
      currentResolvedScope.childScopes.add(resolvedScope);

      super.visitFunctionDeclaration(node);
      scope = currentScope;
    } else {
      return super.visitFunctionDeclaration(node);
    }
  }

  @override
  void visitLabeledStatement(LabeledStatement node) {
    // If we encounter a `$:` label in the outermost function, that's a
    // reactive update statement.
    if (scope == scopes.root &&
        node.labels.any((l) => l.label.name == _reactiveUpdatesLabel)) {
      final old = _isInReactiveRead;
      _isInReactiveRead = true;
      super.visitLabeledStatement(node);
      _isInReactiveRead = old;
    } else {
      super.visitLabeledStatement(node);
    }
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.name.startsWith(zapPrefix)) {
      // Artificial variable inserted to analyze inline expression from the DOM
      // tree.
      final old = _isInReactiveRead;
      _isInReactiveRead = true;

      super.visitVariableDeclaration(node);

      _isInReactiveRead = old;
    } else {
      final resolved = node.declaredElement;

      if (resolved is LocalVariableElement) {
        final currentScope = scope;
        BaseZapVariable variable;

        if (currentScope is ForBlockVariableScope &&
            resolved.name == currentScope.block.elementVariableName) {
          variable = SubcomponentVariable(
            scope: zapScope,
            declaration: node,
            type: resolved.type,
            element: resolved,
            kind: SubcomponentVariableKind.forBlockElement,
          )..isMutable = true;
        } else if (currentScope is ForBlockVariableScope &&
            resolved.name == currentScope.block.indexVariableName) {
          variable = SubcomponentVariable(
            scope: zapScope,
            declaration: node,
            type: resolved.type,
            element: resolved,
            kind: SubcomponentVariableKind.forBlockIndex,
          )..isMutable = true;
        } else if (currentScope is AsyncBlockVariableScope &&
            resolved.name == currentScope.block.variableName) {
          variable = SubcomponentVariable(
            scope: zapScope,
            declaration: node,
            type: resolved.type,
            element: resolved,
            kind: SubcomponentVariableKind.asyncSnapshot,
          )..isMutable = true;
        } else {
          assert(scope == scopes.root);

          variable = DartCodeVariable(
            scope: zapScope,
            declaration: node,
            element: resolved,
            isProperty: isProp(resolved),
          );
        }

        scopes.addVariable(variable);
      }

      super.visitVariableDeclaration(node);
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _markMutable(node.writeElement);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _markMutable(node.writeElement);
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _markMutable(node.writeElement);
    super.visitPrefixExpression(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final staticElement = node.staticElement;
    if (_isInReactiveRead && staticElement != null) {
      _variableFor(staticElement)?.isInReactiveRead = true;
    }

    if (isWatchFunctionFromDslLibrary(node)) {
      // Usage of the `watch()` macro. It may only be used in a variable
      // declaration, in which case that variable will be updated to the value
      // watched.
      final parent = node.parent;
      if (parent is! InvocationExpression || node != parent.function) {
        // Not used as a call (potentially torn off or something). We implement
        // `watch` as a macro, so this is forbidden.
        resolver.errorReporter
            .reportError(ZapError('watch() must be called directly', null));
        return;
      }

      final grandparent = parent.parent;
      if (grandparent is! VariableDeclaration) {
        resolver.errorReporter.reportError(ZapError(
            'The result of watch() must directly be stored in a variable.',
            null));
        return;
      }

      final variable = scopes.variables[grandparent.declaredElement];
      if (variable is DartCodeVariable) {
        variable
          ..isMutable = true
          ..watching = parent.argumentList.arguments.first;
      }
    }
  }
}

class _DomTranslator extends zap.AstVisitor<void, void> {
  static final _eventRegex = RegExp(r'^on:(\w+)(?:\|(\w+))*$');

  final Resolver resolver;

  ZapVariableScope get scope => resolver.scope.scopes[preparedScope]!;

  final List<PreparedVariableScope> _variableScopes;
  final List<_PendingChildren> _childScopes = [_PendingChildren()];

  TypeSystem get typeSystem => resolver.typeSystem;
  TypeProvider get typeProvider => resolver.typeProvider;
  ErrorReporter get errors => resolver.errorReporter;

  PreparedVariableScope get preparedScope => _variableScopes.last;

  _DomTranslator(this.resolver) : _variableScopes = [resolver.scope.root];

  Expression _resolveExpression(zap.RawDartExpression expr) {
    return resolver.dartAnalysis._resolveExpression(expr);
  }

  DartType _typeOf(Expression expr) {
    return expr.staticType ?? typeProvider.dynamicType;
  }

  void _newChildGroup([_PendingChildren? children]) {
    _childScopes.add(children ?? _PendingChildren());
  }

  void _addChild(ReactiveNode child, [String? slot]) {
    final children = _childScopes.last;

    if (!children.assignableSlotNames.contains(slot)) {
      // todo: report error
    } else if (slot == null) {
      children.children.add(child);
    } else {
      children.slotChildren.putIfAbsent(slot, () => []).add(child);
    }
  }

  _PendingChildren _finishChildGroup() => _childScopes.removeLast();

  void _enterScope(PreparedVariableScope scope) => _variableScopes.add(scope);

  /// Some scopes are necessary when some DOM nodes are treated as a fragment
  /// and generated into a separate class. In particular, this is true for slots
  /// which don't have their own scope in the language but generate into a new
  /// fragment. Having a 1:1 mapping between scopes and fragments simplifies the
  /// generator, so we sometimes add "fake" scopes to generate fragments for
  /// these components.
  ZapVariableScope _virtualChildScope() {
    final fakeChildScope = ZapVariableScope(null)..parent = scope;
    scope.childScopes.add(fakeChildScope);
    return fakeChildScope;
  }

  void _leaveScope() => _variableScopes.removeLast();

  DomFragment _newFragment(List<ReactiveNode> children,
      [ZapVariableScope? scope]) {
    return DomFragment(children, scope ?? this.scope);
  }

  @override
  void visitStringLiteral(zap.StringLiteral e, void a) {
    throw ArgumentError('Should have been desugared in the preparation step!');
  }

  @override
  void visitAdjacentNodes(zap.AdjacentNodes e, void arg) {
    for (final child in e.children) {
      child.accept(this, arg);
    }
  }

  @override
  void visitAwaitBlock(zap.AwaitBlock e, void arg) {
    _enterScope(preparedScope.children
        .singleWhere((s) => s is AsyncBlockVariableScope && s.block == e));

    final expr = _resolveExpression(e.futureOrStream);
    DartType inner;
    if (e.isStream) {
      inner =
          resolver.checker.checkStream(_typeOf(expr), e.futureOrStream.span);
    } else {
      inner =
          resolver.checker.checkFuture(_typeOf(expr), e.futureOrStream.span);
    }

    _newChildGroup();
    e.innerNodes.accept(this, arg);

    final block = ReactiveAsyncBlock(
      isStream: e.isStream,
      type: inner,
      expression: expr,
      fragment: _newFragment(_finishChildGroup().children),
    );
    _addChild(block);
    _leaveScope();
  }

  @override
  void visitAttribute(zap.Attribute e, void arg) {
    throw ArgumentError('Should not be reached');
  }

  @override
  void visitComment(zap.Comment e, void a) {
    // ignore
  }

  @override
  void visitRawDartExpression(zap.RawDartExpression e, void arg) {
    throw ArgumentError('Should not be reached');
  }

  @override
  void visitElement(zap.Element e, void arg) {
    List<ReactiveNode> readChildren() {
      _newChildGroup();
      e.innerContent?.accept(this, arg);
      return _finishChildGroup().children;
    }

    final binders = <ElementBinder>[];
    final handlers = <EventHandler>[];
    final attributes = <String, ReactiveAttribute>{};
    String? slot;

    for (final attribute in e.attributes) {
      final key = attribute.key;
      // The pre-process step will replace all attributes with Dart expressions.
      final value =
          _resolveExpression((attribute.value as zap.DartExpression).code);

      final eventMatch = _eventRegex.firstMatch(key);
      if (eventMatch != null) {
        // This attribute uses the `on:` syntax to listen for events.
        final name = eventMatch.group(1)!;
        final modifiers = List.generate(eventMatch.groupCount - 1,
                (index) => eventMatch.group(index + 1)!)
            .map(parseEventModifier)
            .whereType<EventModifier>()
            .toSet();

        final checkResult = resolver.checker.checkEvent(attribute, name, value);
        handlers.add(EventHandler(name, checkResult.known, modifiers, value,
            checkResult.dropParameter));
      } else if (key.startsWith('bind:')) {
        // Bind an attribute of this element to a variable.
        final attributeName = key.substring('bind:'.length);

        final target = value;
        if (target is! SimpleIdentifier || target.staticElement == null) {
          resolver.errorReporter.reportError(ZapError(
              'Target for `bind:` must be a local variable',
              attribute.value?.span));
          continue;
        }
        final zapTarget = resolver.scope.variables[target.staticElement];
        if (zapTarget is! DartCodeVariable) continue;

        zapTarget.isMutable = true;
        if (attributeName == 'this') {
          binders.add(BindThis(zapTarget));
        } else {
          binders.add(BindAttribute(attributeName, zapTarget));
        }
      } else if (key == 'slot') {
        slot = (value as SimpleStringLiteral).value;
      } else {
        // A regular attribute it is then.
        final type = _typeOf(value);
        AttributeMode mode;
        if (typeSystem.isPotentiallyNullable(type)) {
          mode = AttributeMode.setIfNotNullClearOtherwise;
        } else if (typeSystem.isAssignableTo(type, typeProvider.boolType)) {
          mode = AttributeMode.addIfTrue;
        } else {
          mode = AttributeMode.setValue;
        }

        attributes[key] = ReactiveAttribute(value, mode);
      }
    }

    final external = resolver.components
        .firstWhereOrNull((component) => component.className == e.tagName);

    if (external != null) {
      // Tag references another zap component
      _newChildGroup(_PendingChildren(assignableSlotNames: external.slotNames));
      e.innerContent?.accept(this, arg);
      final result = _finishChildGroup();

      // We're using virtual child scopes here because slots are generated into
      // fragments, and each fragment needs to have a unique scope.
      _addChild(
        SubComponent(
          component: external,
          expressions: {},
          defaultSlot: result.children.isEmpty
              ? null
              : _newFragment(result.children, _virtualChildScope()),
          slots: {
            for (final entry in result.slotChildren.entries)
              entry.key: _newFragment(entry.value, _virtualChildScope()),
          },
        ),
        slot,
      );
    } else if (e.tagName == 'slot') {
      // Declares a slot mounting a fragment passed through another component.
      String? slotName;
      if (attributes.containsKey('name')) {
        final name = attributes['name']!.backingExpression;
        if (name is SimpleStringLiteral) {
          slotName = name.value;
        }
      }

      // Use a virtual child scope because the default slot contents are
      // generated as a new fragment class.
      _addChild(
          MountSlot(
              slotName, _newFragment(readChildren(), _virtualChildScope())),
          slot);
    } else if (e.tagName == 'zap:component') {
      final expr = attributes['this'];
      if (expr == null) {
        resolver.errorReporter.reportError(ZapError.onNode(e,
            'Components need a `this` attribute evaluating to the component'));
      } else {
        _addChild(DynamicSubComponent(expr.backingExpression));
      }
    } else {
      // Regular HTML component then
      final known = knownTags[e.tagName.toLowerCase()];
      _addChild(
          ReactiveElement(
              e.tagName, known, attributes, handlers, readChildren(), binders),
          slot);
    }
  }

  @override
  void visitForBlock(zap.ForBlock e, void arg) {
    _enterScope(preparedScope.children
        .whereType<ForBlockVariableScope>()
        .singleWhere((s) => s.block == e));

    _newChildGroup();
    e.body.accept(this, arg);
    final children = _finishChildGroup().children;

    final expr = _resolveExpression(e.iterable);
    final innerType =
        resolver.checker.checkIterable(_typeOf(expr), e.iterable.span);

    _addChild(ReactiveFor(expr, innerType, _newFragment(children)));
    _leaveScope();
  }

  @override
  void visitHtmlTag(zap.HtmlTag e, void a) {
    final expression = _resolveExpression(e.expression);

    _addChild(ReactiveRawHtml(
      expression: expression,
      needsToString: !resolver.checker.isString(
        _typeOf(expression),
      ),
    ));
  }

  @override
  void visitIfBlock(zap.IfBlock e, void arg) {
    _enterScope(preparedScope.children
        .singleWhere((s) => s is SubFragmentScope && s.forNode == e));

    final conditions = <Expression>[];
    final whens = <List<ReactiveNode>>[];
    List<ReactiveNode>? otherwise;

    Expression checkBoolean(zap.RawDartExpression dart) {
      final condition = _resolveExpression(dart);
      final type = _typeOf(condition);
      if (!typeSystem.isSubtypeOf(type, typeProvider.boolType)) {
        errors.reportError(ZapError('Not a `bool` expression!', dart.span));
      }

      return condition;
    }

    zap.IfBlock? currentIf = e;
    while (currentIf != null) {
      conditions.add(checkBoolean(currentIf.condition));

      _newChildGroup();

      currentIf.then.accept(this, arg);
      whens.add(_finishChildGroup().children);

      final orElse = currentIf.otherwise;
      if (orElse is zap.IfBlock) {
        currentIf = orElse;
      } else {
        if (orElse != null) {
          _newChildGroup();

          orElse.accept(this, arg);
          otherwise = _finishChildGroup().children;
        }
        currentIf = null;
      }
    }

    final whenFragments = [for (final when in whens) _newFragment(when)];
    final otherwiseFragment =
        otherwise == null ? null : _newFragment(otherwise);

    _addChild(ReactiveIf(conditions, whenFragments, otherwiseFragment));
    _leaveScope();
  }

  @override
  void visitKeyBlock(zap.KeyBlock e, void a) {
    _enterScope(preparedScope.children
        .singleWhere((s) => s is SubFragmentScope && s.introducedFor == e));

    _newChildGroup();
    e.content.accept(this, a);
    final expr = _resolveExpression(e.expression);
    final fragment = _newFragment(_finishChildGroup().children);

    _addChild(ReactiveKeyBlock(expr, fragment));
    _leaveScope();
  }

  @override
  void visitText(zap.Text e, void arg) {
    _addChild(ConstantText(e.content));
  }

  @override
  void visitDartExpression(zap.DartExpression e, void arg) {
    final expr = resolver.dartAnalysis._resolveExpression(e.code);

    // Tell the generator to add a .toString() call if this expression isn't a
    // string already.
    final needsToString = !resolver.checker.isString(_typeOf(expr));

    _addChild(ReactiveText(expr, needsToString));
  }
}

class _PendingChildren {
  final List<ReactiveNode> children = [];

  /// All slots that can be assigned in the current context (with the unnamed
  /// slot being represented as null).
  ///
  /// This set will be empty when not immediately below a subcomponent.
  final List<String?> assignableSlotNames;
  final Map<String, List<ReactiveNode>> slotChildren = {};

  _PendingChildren({this.assignableSlotNames = const [null]});
}

class _FindComponents {
  final Resolver resolver;
  final DomFragment root;
  final List<String?> usedSlots;

  _FindComponents(this.resolver, this.root, this.usedSlots);

  Component inferComponent() {
    final rootScope = resolver.scope.scopes[resolver.scope.root]!;
    final variables = {
      for (final variable in rootScope.declaredVariables)
        variable.element: variable,
    };

    final body =
        rootScope.function?.functionExpression.body as BlockFunctionBody;

    final resolved = _findFlowUpdates(variables, root, body.block.statements);

    return Component(
      resolved.subComponents,
      rootScope,
      root,
      resolved.flow,
      resolved.initializers,
      resolved.instanceFunctions,
      usedSlots,
    );
  }

  _FlowAndCategorizedStatements _findFlowUpdates(
    Map<Element, BaseZapVariable> variables,
    DomFragment fragment,
    List<Statement> statements,
  ) {
    final flows = <Flow>[];
    final functions = <FunctionDeclarationStatement>[];
    final initializers = <ComponentInitializer>[];
    final subComponents = <ResolvedSubComponent>[];

    // Find flow instructions in the component's Dart code
    outer:
    for (final stmt in statements) {
      if (stmt is LabeledStatement) {
        final isReactiveLabel =
            stmt.labels.any((l) => l.label.name == _reactiveUpdatesLabel);

        if (isReactiveLabel) {
          final inner = stmt.statement;
          flows.add(
            Flow(_FindReadVariables.find(inner, variables), SideEffect(inner)),
          );
        }

        initializers.add(InitializeStatement(stmt));
      } else if (stmt is FunctionDeclarationStatement) {
        if (!stmt.functionDeclaration.name.name.startsWith(zapPrefix)) {
          functions.add(stmt);
          initializers.add(InitializeStatement(stmt));
        }
      } else {
        if (stmt is VariableDeclarationStatement) {
          // Filter out __zap__var_1 variables that have only been created to
          // analyze expressions used in the DOM.
          for (final variable in stmt.variables.variables) {
            if (variable.name.name.startsWith(zapPrefix)) {
              continue outer;
            }
            final zapVariable = variables[variable.declaredElement];
            if (zapVariable is DartCodeVariable && zapVariable.isProperty) {
              // We need to generate special code to initialize properties as
              // they can be set as constructor parameters too.
              initializers.add(InitializeProperty(zapVariable));
              continue outer;
            }
          }
        }

        initializers.add(InitializeStatement(stmt));
      }
    }

    void resolveWithoutOwnStatements(DomFragment fragment) {
      final flows = _findFlowUpdates(variables, fragment, []);
      subComponents.add(ResolvedSubComponent(
          flows.subComponents, fragment.resolvedScope, fragment, flows.flow));
    }

    // And also infer it from the DOM
    void processNode(ReactiveNode node) {
      if (node is ReactiveText) {
        final relevant = _FindReadVariables.find(node.expression, variables);
        flows.add(Flow(relevant, ChangeText(node)));
      } else if (node is ReactiveElement) {
        for (final handler in node.eventHandlers) {
          final listener = handler.listener;
          final listenerIsMutable =
              listener is! FunctionReference && listener is! FunctionExpression;

          final relevantVariables = listenerIsMutable
              ? _FindReadVariables.find(listener, variables)
              : <BaseZapVariable>{};
          flows.add(Flow(relevantVariables, RegisterEventHandler(handler)));
        }

        node.attributes.forEach((key, value) {
          final dependsOn =
              _FindReadVariables.find(value.backingExpression, variables);
          flows.add(Flow(dependsOn, ApplyAttribute(node, key)));
        });

        node.children.forEach(processNode);
      } else if (node is ReactiveIf) {
        // Blocks in the if statement will be compiled to lightweight components
        // written into separate classes.
        // However, they don't have any initializer statements and user code.
        for (final when in node.whens) {
          final flow = _findFlowUpdates(variables, when, []);
          subComponents.add(ResolvedSubComponent(
              flow.subComponents, when.resolvedScope, when, flow.flow));
        }

        final otherwise = node.otherwise;
        if (otherwise != null) {
          final flow = _findFlowUpdates(variables, otherwise, []);
          subComponents.add(ResolvedSubComponent(flow.subComponents,
              otherwise.resolvedScope, otherwise, flow.flow));
        }

        // The if should be updated if any variable referenced in any condition
        // updates.
        final finder = _FindReadVariables(variables);
        for (final condition in node.conditions) {
          condition.accept(finder);
        }

        flows.add(Flow(finder.found, UpdateBlockExpression(node)));
      } else if (node is ReactiveAsyncBlock) {
        final scope = node.fragment.resolvedScope;
        final snapshotVariable =
            scope.findForSubcomponent(SubcomponentVariableKind.asyncSnapshot)!;
        final localDeclarations = {snapshotVariable.element: snapshotVariable};

        final flow = _findFlowUpdates(
          {...variables, ...localDeclarations},
          node.fragment,
          [],
        );
        subComponents.add(ResolvedSubComponent(
            flow.subComponents, scope, node.fragment, flow.flow));

        flows.add(Flow(
          _FindReadVariables.find(node.expression, variables),
          UpdateBlockExpression(node),
        ));
      } else if (node is ReactiveFor) {
        final scope = node.fragment.resolvedScope;
        final localDeclarations = {
          for (final variable in scope.declaredVariables)
            variable.element: variable
        };

        final flow = _findFlowUpdates(
          {...variables, ...localDeclarations},
          node.fragment,
          [],
        );
        subComponents.add(ResolvedSubComponent(
            flow.subComponents, scope, node.fragment, flow.flow));

        flows.add(Flow(
          _FindReadVariables.find(node.expression, variables),
          UpdateBlockExpression(node),
        ));
      } else if (node is ReactiveAsyncBlock) {
        final flow = _findFlowUpdates(variables, node.fragment, []);
        subComponents.add(ResolvedSubComponent(flow.subComponents,
            node.fragment.resolvedScope, node.fragment, flow.flow));
        flows.add(Flow(
          _FindReadVariables.find(node.expression, variables),
          UpdateBlockExpression(node),
        ));
      } else if (node is ReactiveRawHtml) {
        flows.add(Flow(
          _FindReadVariables.find(node.expression, variables),
          UpdateBlockExpression(node),
        ));
      } else if (node is MountSlot) {
        resolveWithoutOwnStatements(node.defaultContent);
      } else if (node is SubComponent) {
        // todo: Recognize flows to update props passed to subcomponents.

        final defaultSlot = node.defaultSlot;
        if (defaultSlot != null) {
          resolveWithoutOwnStatements(defaultSlot);
        }

        node.slots.values.forEach(resolveWithoutOwnStatements);
      } else if (node is DynamicSubComponent) {
        flows.add(Flow(_FindReadVariables.find(node.expression, variables),
            UpdateBlockExpression(node)));
      } else {
        node.children.forEach(processNode);
      }
    }

    fragment.rootNodes.forEach(processNode);
    return _FlowAndCategorizedStatements(
        flows, functions, initializers, subComponents);
  }
}

class _FindReadVariables extends GeneralizingAstVisitor<void> {
  final Map<Element, BaseZapVariable> variables;
  final Set<BaseZapVariable> found = {};

  _FindReadVariables(this.variables);

  static Set<BaseZapVariable> find(
      AstNode node, Map<Element, BaseZapVariable> variables) {
    final visitor = _FindReadVariables(variables);
    node.accept(visitor);

    return visitor.found;
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    // Only check RHS of assignment because the LHS doesn't _read_ variables.
    // todo: How should things like `foo.bar = baz` behave - do we count that
    // as reading `foo`?
    node.rightHandSide.accept(this);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    visitIdentifier(node.prefix);
    visitIdentifier(node.identifier);
  }

  @override
  void visitIdentifier(Identifier node) {
    final element = node.staticElement;
    final variable = variables[element];

    if (variable != null) {
      found.add(variable);
    }
  }
}

class _FlowAndCategorizedStatements {
  final List<Flow> flow;
  final List<FunctionDeclarationStatement> instanceFunctions;
  final List<ComponentInitializer> initializers;
  final List<ResolvedSubComponent> subComponents;

  _FlowAndCategorizedStatements(
    this.flow,
    this.instanceFunctions,
    this.initializers,
    this.subComponents,
  );
}

class ResolvedComponent {
  final String componentName;
  final String? cssClassName;
  final Component component;

  ResolvedComponent(this.componentName, this.component, this.cssClassName);
}
