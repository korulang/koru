pub tor collide { ax: f32, ay: f32, ar: f32, bx: f32, by: f32, br: f32 } -> bool

collide -> (ax - bx) * (ax - bx) + (ay - by) * (ay - by) <= (ar + br) * (ar + br)
