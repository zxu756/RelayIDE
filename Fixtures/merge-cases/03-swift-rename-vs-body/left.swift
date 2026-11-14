struct S {
    func calculate(x: Int) -> Int {
        let y = x * 2
        return y + 1
    }

    func use() -> Int {
        calculate(x: 3)
    }
}
