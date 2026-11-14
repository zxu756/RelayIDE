import Foundation

struct Calc {
    func total(items: [Int]) -> Int {
        var sum = 0
        let offset = 1
        for i in items {
            sum += i
        }
        let tax = 2
        sum += tax
        let bonus = 30
        sum += bonus
        return sum + offset
    }

    func other() -> Int { 7 }
}
