struct Report {
    let title: String

    var body: String {
        """
        Title: \(title)

        -- end of report --
        """
    }

    func lineCount() -> Int {
        body.split(separator: "\n").count
    }

    @available(macOS 14, *)
    func uppercased() -> String {
        body.uppercased()
    }
}
