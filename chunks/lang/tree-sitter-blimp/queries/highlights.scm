; Keywords
"actor" @keyword
"do" @keyword
"end" @keyword
"state" @keyword
"on" @keyword
"become" @keyword
"reply" @keyword
"situation" @keyword
"case" @keyword
"orelse" @keyword
"when" @keyword
"bubbles" @keyword
"spawn" @keyword

; Literals
(integer) @number
(float) @number.float
(string) @string
(atom) @string.special.symbol
(boolean) @constant.builtin
(nil) @constant.builtin
(hole) @variable.builtin

; Identifiers
(upper_identifier) @type
(identifier) @variable

; Function calls
(function_call
  (identifier) @function.call)

; Actor name
(actor_name
  (upper_identifier) @type.definition)

; Message handler name
(message_handler
  (atom) @function.method)

; Parameters
(parameter_list
  (identifier) @variable.parameter)

; Key in key-value pairs
(key_value_pair
  (identifier) @property)

; Operators
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"=" @operator
"==" @operator
"!=" @operator
"<" @operator
">" @operator
"<=" @operator
">=" @operator
"||" @operator
"&&" @operator
"!" @operator
"|" @operator
"|>" @operator
"->" @operator
"<-" @operator
"." @punctuation.delimiter

; Delimiters
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"," @punctuation.delimiter
":" @punctuation.delimiter
"%" @punctuation.delimiter

; Comments
(comment) @comment
