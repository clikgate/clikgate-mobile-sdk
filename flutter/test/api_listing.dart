// Public-API listing of a package's main library, from a syntactic parse
// (package:analyzer `parseFile`, no resolution). Follows `export` directives
// with their show/hide combinators and lists public top-level declarations
// and their public members (signatures without bodies, doc comments or
// initializer values). Copied verbatim into flutter_engage/test/: keep both
// copies identical.
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

List<String> apiListing(String libraryPath) {
  final out = <String>[];
  _library(File(libraryPath), null, const {}, out, {});
  return out;
}

void _library(File file, Set<String>? show, Set<String> hide, List<String> out, Set<String> seen) {
  final path = file.absolute.path;
  if (!seen.add('$path|$show|$hide')) return;
  final unit = parseFile(path: path, featureSet: FeatureSet.latestLanguageVersion()).unit;
  bool visible(String name) =>
      !name.startsWith('_') && !hide.contains(name) && (show == null || show.contains(name));

  for (final d in unit.directives.whereType<ExportDirective>()) {
    final uri = d.uri.stringValue!;
    if (uri.startsWith('package:') || uri.startsWith('dart:')) {
      out.add('export $uri');
      continue;
    }
    Set<String>? s = show;
    var h = {...hide};
    for (final c in d.combinators) {
      final names = c is ShowCombinator
          ? c.shownNames.map((n) => n.name).toSet()
          : (c as HideCombinator).hiddenNames.map((n) => n.name).toSet();
      if (c is ShowCombinator) {
        s = s == null ? names : s.intersection(names);
      } else {
        h = {...h, ...names};
      }
    }
    _library(File('${file.parent.path}/$uri'), s, h, out, seen);
  }

  for (final d in unit.declarations) {
    final name = switch (d) {
      ClassDeclaration c => c.name.lexeme,
      EnumDeclaration e => e.name.lexeme,
      MixinDeclaration m => m.name.lexeme,
      ExtensionDeclaration e => e.name?.lexeme ?? '_',
      GenericTypeAlias t => t.name.lexeme,
      FunctionTypeAlias t => t.name.lexeme,
      FunctionDeclaration f => f.name.lexeme,
      TopLevelVariableDeclaration v => v.variables.variables.first.name.lexeme,
      _ => '_',
    };
    if (!visible(name)) continue;
    switch (d) {
      case ClassDeclaration c:
        out.add(_header(c, c.leftBracket));
        _members(c.members, out);
      case EnumDeclaration e:
        out.add(_header(e, e.leftBracket));
        for (final k in e.constants) {
          out.add('  ${k.name.lexeme}');
        }
        _members(e.members, out);
      case MixinDeclaration m:
        out.add(_header(m, m.leftBracket));
        _members(m.members, out);
      case ExtensionDeclaration x:
        out.add(_header(x, x.leftBracket));
        _members(x.members, out);
      case FunctionDeclaration f:
        out.add(_until(f, f.functionExpression.body.beginToken));
      case TopLevelVariableDeclaration v:
        for (final x in v.variables.variables) {
          out.add('${_varPrefix(v.variables)}${x.name.lexeme}');
        }
      default:
        out.add(_squash(_text(d.firstTokenAfterCommentAndMetadata, d.endToken)));
    }
  }
}

void _members(List<ClassMember> members, List<String> out) {
  for (final m in members) {
    switch (m) {
      case ConstructorDeclaration c:
        final n = c.name?.lexeme;
        if (n != null && n.startsWith('_')) continue;
        final stop = c.separator ?? (c.body is EmptyFunctionBody ? c.body.endToken : c.body.beginToken);
        out.add('  ${_until(c, stop)}');
      case MethodDeclaration md:
        if (md.name.lexeme.startsWith('_')) continue;
        out.add('  ${_until(md, md.body.beginToken)}');
      case FieldDeclaration f:
        for (final v in f.fields.variables) {
          if (v.name.lexeme.startsWith('_')) continue;
          out.add('  ${f.isStatic ? 'static ' : ''}${_varPrefix(f.fields)}${v.name.lexeme}');
        }
    }
  }
}

String _varPrefix(VariableDeclarationList l) =>
    '${l.lateKeyword != null ? 'late ' : ''}${l.keyword != null ? '${l.keyword!.lexeme} ' : ''}'
    '${l.type != null ? '${l.type!.toSource()} ' : ''}';

String _header(Declaration d, Token leftBracket) => _until(d, leftBracket);

/// Source from the declaration's first token (after doc comment / metadata)
/// up to, excluding, [stop].
String _until(AstNode d, Token stop) {
  final first = (d as AnnotatedNode).firstTokenAfterCommentAndMetadata;
  if (identical(first, stop)) return '';
  return _squash(_text(first, stop.previous!));
}

String _text(Token first, Token last) {
  const noSpaceBefore = {'(', ')', ',', '<', '>', '?', ']', '}', '.', ';', ':', '!'};
  const noSpaceAfter = {'(', '<', '[', '{', '.', '@'};
  final b = StringBuffer();
  String? prev;
  for (Token? t = first; t != null; t = t.next) {
    final lex = t.lexeme;
    if (prev != null && !noSpaceBefore.contains(lex) && !noSpaceAfter.contains(prev)) b.write(' ');
    b.write(lex);
    prev = lex;
    if (identical(t, last)) break;
  }
  return b.toString();
}

String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
