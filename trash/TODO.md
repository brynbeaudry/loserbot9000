# LOSERBOT9000 TODO LIST (Organized)

## EMA Strategy Improvements

- Need to have a value threshold that an EMA needs to cross over be higher. In order to reverse a trend, it needs to be a certain amount over the EMA. We do this to avoid noise if we're trending up or down more generally.
- Don't automatically reverse your position until the closing position of a previous candle is a certain threshold over the slow EMA
  - Lots of reversals that cost you have turned out to not need to be reversed after the candle closes.

  - Let SL Take care of things once you are in a positioon. Cross over happen some much on a trend, don''t listen to small crossovers as a way to exit the position. 

  - Maybe try only buying after close, exactly on the oppppen of the next one once you've made the decison

  - Ema cross over in the other direction needs to be a trend when you are in a positioon. THis just needs to be safe, remember, it's running all day. 

## Stop Loss / Take Profit Enhancements

- Positioooon closing (sltp) can be done based on MACD
- Use average leg size of the last X timeframe to calculate where to put your TP line.
- Find a way to automatically find that support line to set take profit, or the stop loss
- Otherwise set a percentage of the stock price for the TP that makes sense

## Code Review

- Look over sectioons of your code and identify the most useful ones. 


## Position Management

- We can also time box your position profiting, in addition to setting SL/TP. That's one advantage that automated trading has.

## Indicator Issues

- Think our VWAP isn't making sense

## Data Analysis & Visualization

- Feed AI picture of what you're trying to read
- Utilize candle based timing, and candle based stats history for decision more generally
- Know how to do this without the AI
- Know exactly what kind of data that you have in your data frame history
- Know difference between live information and your data history

## I call it "Code Taking":

- Search github repos of bots to convert to this system and try out.
- https://github.com/ryu878/Bybit-BTCUSD-Inverse-Perpetual-Scalp-Trading-Bot/blob/main/inverse_bot_v5.0.py
--> Make it lame and gay. Turn it into AI slop