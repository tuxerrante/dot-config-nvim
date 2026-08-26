(rule
  (targets
    (word) @name)
  (#not-match? @name "^\\.")
  (#set! "kind" "Function")) @symbol
