struct S {
    func compute(x: Int) -> Int {
        let y = x * 3
        return y + 1
    }

    func use() -> Int {
        compute(x: 3)
    }
}
