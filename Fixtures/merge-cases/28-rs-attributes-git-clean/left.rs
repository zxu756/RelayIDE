#[derive(Debug, Clone)]
pub struct Point {
    pub x: i32,
    pub y: i32,
}

impl Point {
    pub fn norm1(&self) -> i32 {
        self.x.abs() + self.y.abs()
    }

    pub fn origin() -> Point {
        Point { x: 0, y: 0 }
    }
}
