from luaparser import ast

for name in ("Function", "AnonymousFunction", "LocalFunction", "Invoke", "LocalAssign",
             "Assign", "Fornum", "Forin", "Field", "Index", "Call", "Name"):
    cls = getattr(ast, name, None)
    print(name, [c.__name__ for c in cls.__mro__] if cls else "MISSING")