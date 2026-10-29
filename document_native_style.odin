package main

Native_Display :: enum {Inline,Inline_Block,Block,None,Flex,Grid,Table,Row,Cell}
Native_Position :: enum {Static,Relative,Absolute,Fixed,Sticky}
Native_Alignment :: enum {Start,End,Center,Stretch,Between,Around,Evenly,Baseline}
Native_Style :: struct {
    display:Native_Display,
    custom_properties:map[string]string,
    position:Native_Position,
    color,background,border:Color,
    size,parent_size,line_height,width,height,max_width:f32,
    width_percent:f32,
    width_rule,height_rule,min_width_rule,max_width_rule,min_height_rule,max_height_rule:string,
    margin,padding:[4]f32,
    margin_rule,padding_rule,inset:[4]string,
    border_width:f32,
    border_edges:[4]f32,
    bold,italic,mono,underline,pre,pre_wrap,nowrap,hidden,border_box:bool,
    clip_x,clip_y:bool,
    align:int,
    flex_direction,flex_wrap:int,
    flex_grow,flex_shrink:f32,
    flex_basis:string,
    justify,align_items,align_content,align_self,justify_items,justify_self:Native_Alignment,
    self_explicit,justify_self_explicit:bool,
    gap:[2]string,
    order,z_index:int,
    grid_columns,grid_rows,grid_auto_columns,grid_auto_rows:string,
    grid_column,grid_row,grid_column_span,grid_row_span:int,
    grid_column_flow:bool,
    table_columns:int,
}
