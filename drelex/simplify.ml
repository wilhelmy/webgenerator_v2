(*
\subsection{Simplification}
\label{simplify}

This module implements some transformations of regular expressions.  It
operates directly on the tree representation of parsed regular expressions.
After simplification, the expression is guaranteed to only contain the
following kinds of sub-expressions:

\begin{itemize}
  \item Sequences ([[a b]])
  \item Alternations ([[a | b]])
  \item Non-empty iterations (the [[+]] operator)
  \item Simple character classes without ranges ([[[abcd...]]])
  \item Single characters ([['a']])
\end{itemize}

This reduction or desugaring is performed so that the NFA construction step can
be kept simple. Only in cases where the NFA module could produce much better
automata by knowing a higher level of expressions, we keep the originals.

The transformations here expect the expressions to be fully resolved.  See
\ref{resolve} for symbol resolution.
*)
open Ast
(*
We define a regular expression matching the full character range.  This is used
for the wildcard expression [['_']]. We construct a single global immutable
object and use it to reduce all wildcards.
*)
let full_chr_class =
  CharClass (CharClass.of_list CharClass.full_chr_list)

(*
Simplify a character class containing ranges to one containing all characters
in the range, separately. The actual work is done in the [[CharClass]] module.
This function wraps the result into a [[regexp]] object.

E.g. [[[0-9]]] will be transformed into [[[0123456789]]].
*)
let simplify_char_class cc =
  CharClass (CharClass.of_list (CharClass.to_chr_list cc))



let simplify_property = function
  | NameProperty (prop, value) ->
      failwith "unsupported: name-property"
  | IntProperty (prop, value) ->
      failwith "unsupported: int-property"

(*
Recursively simplify regexps and their sub-expressions.
*)
let rec simplify_regexp = function
(*
  Sequences and alternations containing only a single sub-regexp will not be
  produced by the parser, but in case another transformation produced one, we
  replace it by its only child after resolving it.
*)
  | Sequence [regexp]
  | Alternation [regexp] ->
      Diagnostics.warning Sloc.empty_string
        "Sequence or alternation with single element found";
      simplify_regexp regexp

(*
  Sequences, alternations, iterations and name bindings are not reduced any
  further. Their children are recursively simplified.
*)
  | Sequence list -> Sequence (List.map simplify_regexp list)
  | Alternation list -> Alternation (List.map simplify_regexp list)
  | Intersection list -> Intersection (List.map simplify_regexp list)
  | Star re -> Star (simplify_regexp re)
  | Negation re -> Negation (simplify_regexp re)
  | Binding (re, name) -> Binding (simplify_regexp re, name)

(*
  The ``optional'' quantifier is transformed into an alternation with the empty
  sentence.
  
  I.e. $a? \rightarrow (a | \varepsilon)$
*)
  | Question re -> Alternation [epsilon; simplify_regexp re]

(*
  The one-to-many quantifier ``+'' can be expressed as sequence of the
  expression itself and the expression under Kleene star ``*''.
  
  I.e. $a* \rightarrow (a+ | \varepsilon)$
*)
  | Plus re ->
      let re = simplify_regexp re in
      Sequence [re; Star re]

(*
  % TODO: the parser cannot produce these, at the moment,
  % but when it can, we need to support it here
*)
  | Quantified (re, low, high) ->
      failwith "unsupported: {n,m} quantifier"

(*
  Unicode character properties are handled separately and the produced regexp
  may contain arbitrary expressions that are subsequently simplified.
*)
  | CharProperty prop ->
      simplify_regexp (simplify_property prop)

(*
  Character classes are handled by the [[CharClass]] module and the resulting
  expression requires no further simplification.  Note that we could express
  character classes as an alternation over each character, but that would cause
  the NFA construction to generate $n$ states for $n$ characters in the class,
  so instead of simplifying it here, we handle it specially in the NFA step.
*)
  | CharClass cc ->
      simplify_char_class cc

(*
  The ``any character'' wildcard expression is resolved as a character class
  containing the full character set.
*)
  | AnyChar ->
      full_chr_class

(*
  String literals are expressed as sequence of their characters in order. We
  could do this in the NFA directly, but the performance improvement is so low
  that it's not worth it.
*)
  | String s ->
      Sequence (
        BatString.fold_right (fun c chars ->
          Char (Sloc.at s c) :: chars
        ) (Sloc.value s) []
      )

(*
  Single characters and the end-of-file symbol need no further simplification.
*)
  | Eof
  | Char _ as atom ->
      atom

(*
  The simplifier has no knowledge of aliases, so it is an error if we try to
  simplify one.
*)
  | Lexeme _ ->
      failwith "cannot simplify unresolved alias"


(*
Simplify all regular expressions in all rules for a lexer function.  The
semantic actions are not touched.
*)
let simplify_lexer (Lexer (name, args, rules)) =
  let rules =
    List.map (fun (Rule (regexp, code)) ->
      Rule (simplify_regexp regexp, code)
    ) rules
  in
  Lexer (name, args, rules)


(*
Produce a new program with simplified rules. This function never produces fatal
diagnostics.
*)
let simplify (Program (pre, aliases, lexers, post)) =
  if aliases != [] then
    failwith "cannot simplify program with unresolved aliases";
  let lexers = List.map simplify_lexer lexers in

  Program (pre, [], lexers, post)
