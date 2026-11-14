struct S {
    func compute(x: Int) -> Int {
        let y = x * 2
        return y + 1
    }

    func use() -> Int {
        compute(x: 3)
    }
}
