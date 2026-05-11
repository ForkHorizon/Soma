struct Greeter {
    func greet(name: String) -> String {
        "Hello, \(name)"
    }
}

print(Greeter().greet(name: "Soma"))
