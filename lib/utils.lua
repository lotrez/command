FORMAT_JOKER = function(joker)
  return {
    name = joker.ability.name,
    debuffed = joker.debuff,
    sellPrice = joker.sell_cost,
    effect = joker.ability.effect,
    id = joker.sort_id
  }
end

FORMAT_PLAYING_CARD = function(card)
  return {
    suit = card.base.suit,
    rank = card.base.value,
    id = card.sort_id,
    name = card.ability.name,
    seal = card.seal,
    effect = card.ability.effect,
    debuffed = card.debuff
  }
end

FORMAT_SHOP_CARD = function(card)
  return {
    cost = card.cost,
    rank = card.base and card.base.value or nil,
    id = card.sort_id,
    name = card.ability and card.ability.name or nil,
    seal = card.seal,
    effect = card.ability and card.ability.effect or nil,
    type = card.ability and card.ability.set or nil
  }
end

FORMAT_CONSUMABLE = function(card)
  return {
    name = card.ability.name,
    sellPrice = card.sell_cost,
    id = card.sort_id
  }
end

FORMAT_BOOSTER_CARD = function(card)
  return {
    rank = card.base and card.base.value or nil,
    id = card.sort_id,
    name = card.ability and card.ability.name or nil,
    seal = card.seal,
    effect = card.ability and card.ability.effect or nil,
    type = card.ability and card.ability.set or nil
  }
end
