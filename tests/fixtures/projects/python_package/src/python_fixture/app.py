class Greeter:
    def greet(self, name: str) -> str:
        return f"Hello, {name}"


def main() -> None:
    print(Greeter().greet("Soma"))
